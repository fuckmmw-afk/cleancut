import BackgroundTasks
import UIKit

/// Не даёт системе усыпить приложение во время долгой обработки.
///
/// iOS 18–25: держим экран включённым, сворачивать приложение нельзя.
/// iOS 26+: дополнительно просим у системы BGContinuedProcessingTask, тогда этапы на CPU и Neural Engine
/// переживают сворачивание. LLM работает на GPU, а GPU в фоне недоступен, поэтому она ждёт возврата в приложение.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var activeCount = 0
    private var registered = false
    private var continuedTask: AnyObject?
    private var title = ""

    /// true, если система выдала фоновую задачу и приложение можно свернуть.
    private(set) var hasBackgroundTask = false

    private var identifier: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let candidate = bundleID + ".processing"
        // После переподписи bundle id может измениться, а Info.plist нет. Регистрация идентификатора,
        // которого нет в Info.plist, роняет приложение, поэтому сначала сверяемся.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return permitted?.contains(candidate) == true ? candidate : nil
    }

    func registerIfPossible() {
        guard #available(iOS 26.0, *), !registered, let identifier else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated {
                BackgroundKeeper.shared.adopt(task)
            }
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        guard activeCount > 0 else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        hasBackgroundTask = true
        task.progress.totalUnitCount = 1000
        task.expirationHandler = {
            Task { @MainActor in
                BackgroundKeeper.shared.hasBackgroundTask = false
                BackgroundKeeper.shared.continuedTask = nil
            }
        }
    }

    /// Начало долгой операции.
    func begin(title: String) {
        activeCount += 1
        self.title = title
        UIApplication.shared.isIdleTimerDisabled = true

        guard #available(iOS 26.0, *), registered, let identifier, continuedTask == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title, subtitle: "Обработка идёт на устройстве")
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Обновляет прогресс в системной карточке фоновой задачи.
    func update(progress: Double, subtitle: String) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64((min(max(progress, 0), 1) * 1000).rounded())
        task.updateTitle(title, subtitle: subtitle)
    }

    func end(success: Bool) {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false

        if #available(iOS 26.0, *) {
            if let task = continuedTask as? BGContinuedProcessingTask {
                task.setTaskCompleted(success: success)
            } else if registered, let identifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
        }
        continuedTask = nil
        hasBackgroundTask = false
    }
}
