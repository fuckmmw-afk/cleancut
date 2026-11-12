import Foundation
import os

/// Журнал анализа в папке проекта. Его можно отправить разработчику из экрана ревью.
final class AnalysisLog: Sendable {
    let url: URL
    private let lock = OSAllocatedUnfairLock()

    init(projectID: UUID) {
        url = ProjectStore.directory(for: projectID).appendingPathComponent("analysis.log")
    }

    static func url(for projectID: UUID) -> URL {
        ProjectStore.directory(for: projectID).appendingPathComponent("analysis.log")
    }

    func write(_ message: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let line = "[\(stamp)] \(message)\n"
        lock.withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    func memory(_ label: String) {
        write("\(label): доступно памяти \(Format.bytes(MemoryBudget.available)), нагрев \(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    func header(settings: PipelineSettings, project: Project) {
        let device = ProcessInfo.processInfo
        write(
            "=== Анализ: \(project.title), \(Format.duration(project.duration)), \(project.width)×\(project.height) @ \(project.fps) fps"
        )
        write(
            "iOS \(device.operatingSystemVersionString), RAM \(Format.bytes(Int64(device.physicalMemory))), версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")"
        )
        write(
            "Настройки: пауза ≥ \(settings.minPause) с, отступ \(Int(settings.padding * 1000))/\(Int(settings.tailPadding * 1000)) мс, Whisper \(settings.whisperModel.title), дубли \(settings.retakeModel.title), Silero \(settings.useSilero)"
        )
    }
}

/// Флаг «приложение на экране», который можно читать с любого потока.
final class ForegroundFlag: Sendable {
    static let shared = ForegroundFlag()

    private let state = OSAllocatedUnfairLock(initialState: true)

    var isForeground: Bool { state.withLock { $0 } }
    func set(_ value: Bool) { state.withLock { $0 = value } }

    /// Блокирует текущий (фоновый) поток, пока приложение не вернётся на экран.
    /// - Returns: false, если ожидание прервано отменой.
    func waitBlocking(cancelled: CancelFlag) -> Bool {
        while !isForeground {
            if cancelled.isSet { return false }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return !cancelled.isSet
    }
}
