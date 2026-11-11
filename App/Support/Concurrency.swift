import Foundation
import UIKit
import os

/// Потокобезопасный флаг отмены для колбэков, которые вызываются вне нашей задачи.
final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// GPU (а значит, и MLX) в фоне недоступен: система убивает приложение за работу с Metal.
/// Поэтому перед каждым шагом генерации ждём, пока приложение снова окажется на экране.
enum ForegroundGate {
    @MainActor
    static var isForeground: Bool { UIApplication.shared.applicationState != .background }

    static func waitUntilForeground() async throws {
        while !(await isForeground) {
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

/// Сколько памяти приложение ещё может занять до того, как система его убьёт.
enum MemoryBudget {
    static var available: Int64 { Int64(os_proc_available_memory()) }
}

/// Пропускает не больше одного значения прогресса за интервал, чтобы не заваливать главный поток.
final class ProgressThrottle: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: ContinuousClock.Instant?.none)
    private let interval: Duration
    private let handler: @MainActor @Sendable (Double) -> Void

    init(interval: Duration = .milliseconds(100), handler: @escaping @MainActor @Sendable (Double) -> Void) {
        self.interval = interval
        self.handler = handler
    }

    func report(_ value: Double) {
        let now = ContinuousClock.now
        let interval = interval
        let pass = last.withLock { last -> Bool in
            if value < 1, let previous = last, now - previous < interval { return false }
            last = now
            return true
        }
        guard pass else { return }
        let handler = handler
        Task { @MainActor in handler(value) }
    }
}

/// Обёртка для объектов AVFoundation, которые не помечены Sendable, но используются строго на одной очереди.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
