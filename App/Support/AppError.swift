import Foundation

/// Ошибка с понятным человеку текстом. Всё, что показывается пользователю, проходит через неё.
struct AppError: LocalizedError, Sendable {
    var title: String
    var message: String

    init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }

    var errorDescription: String? { message }

    /// Превращает любую ошибку в текст для пользователя.
    static func wrap(_ error: any Error, title: String = "Что-то пошло не так") -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return AppError("Отменено", "Операция отменена.") }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return AppError(
                "Нет сети",
                "Не получилось скачать модель. Проверь интернет и попробуй ещё раз. Сеть нужна только для первой загрузки моделей."
            )
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return AppError("Мало места", "На айфоне закончилось свободное место. Освободи память и попробуй снова.")
        }
        return AppError(title, nsError.localizedDescription)
    }

    static func notEnoughSpace(needed: Int64, available: Int64) -> AppError {
        AppError(
            "Мало места",
            "Нужно примерно \(Format.bytes(needed)) свободного места, а доступно \(Format.bytes(available)). Освободи память и попробуй снова."
        )
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// 83.4 → «1:23»
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// 83.44 → «1:23.4»
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        return String(format: "%d:%04.1f", minutes, total - Double(minutes * 60))
    }
}

enum Disk {
    /// Свободное место, которое система готова отдать под важные данные.
    static func available() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func ensure(_ needed: Int64) throws {
        let free = available()
        if free < needed { throw AppError.notEnoughSpace(needed: needed, available: free) }
    }
}
