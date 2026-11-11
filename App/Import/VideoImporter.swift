import AVFoundation
import Foundation

/// Копирует видео в песочницу проекта и читает его параметры. Файл никогда не грузится в память целиком.
enum VideoImporter {

    enum Source: Sendable {
        /// Файл из «Файлов»: нужен security-scoped доступ, копируем.
        case external(URL)
        /// Файл уже лежит в нашем временном каталоге (после PHPicker): переносим без копирования.
        case staged(URL)
    }

    static var stagingDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Забирает файл, который PHPicker отдаёт только на время колбэка. Перенос внутри одного тома мгновенный.
    static func stage(_ url: URL) throws -> URL {
        let target = stagingDirectory.appendingPathComponent(UUID().uuidString + "." + fileExtension(of: url))
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            try FileManager.default.copyItem(at: url, to: target)
        }
        return target
    }

    static func cleanStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    private static func fileExtension(of url: URL) -> String {
        url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
    }

    static func importVideo(_ source: Source, title: String? = nil) async throws -> Project {
        let id = UUID()
        let directory = ProjectStore.directory(for: id)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try await run(source, id: id, title: title, directory: directory)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if case .staged(let url) = source { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func run(_ source: Source, id: UUID, title: String?, directory: URL) async throws -> Project {
        let manager = FileManager.default
        let original: URL
        switch source {
        case .external(let url), .staged(let url): original = url
        }

        let scoped: Bool
        if case .external = source { scoped = original.startAccessingSecurityScopedResource() } else { scoped = false }
        defer { if scoped { original.stopAccessingSecurityScopedResource() } }

        let size = Disk.fileSize(original)
        guard size > 0 else {
            throw AppError("Файл не читается", "Не получилось открыть видео. Попробуй выбрать его ещё раз.")
        }

        // Нужно место под копию исходника и под готовый ролик, то есть около двух размеров файла.
        // Если файл уже лежит у нас, копия не нужна.
        if case .external = source {
            try Disk.ensure(size * 2)
        } else {
            try Disk.ensure(size)
        }

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "source." + fileExtension(of: original)
        let target = directory.appendingPathComponent(fileName)

        switch source {
        case .external:
            try manager.copyItem(at: original, to: target)
        case .staged:
            try manager.moveItem(at: original, to: target)
        }
        try Task.checkCancellation()

        let info = try await probe(target)
        let name = title ?? original.deletingPathExtension().lastPathComponent
        return Project(
            id: id,
            title: displayTitle(name),
            sourceFileName: fileName,
            fileSize: size,
            duration: info.duration,
            fps: info.fps,
            width: info.width,
            height: info.height)
    }

    private static func displayTitle(_ name: String) -> String {
        // У файлов из Фото имена вроде UUID или IMG_1234, оставляем как есть, но не пустые.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || UUID(uuidString: trimmed) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM, HH:mm"
            return "Видео " + formatter.string(from: Date())
        }
        return trimmed
    }

    struct VideoInfo: Sendable {
        var duration: Double
        var fps: Double
        var width: Int
        var height: Int
    }

    static func probe(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let unreadable = AppError(
            "Видео не открывается", "Этот файл не получается прочитать. Поддерживаются обычные MOV и MP4 с камеры.")
        do {
            guard try await asset.load(.isReadable) else { throw unreadable }
            let duration = try await asset.load(.duration).seconds
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw AppError("Нет видеодорожки", "В файле нет видео.")
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw AppError("Нет звука", "В видео нет звуковой дорожки, а паузы и дубли ищутся по речи.")
            }
            let (naturalSize, transform, frameRate) = try await video.load(
                .naturalSize, .preferredTransform, .nominalFrameRate)
            let oriented = naturalSize.applying(transform)
            guard duration.isFinite, duration > 0.5 else {
                throw AppError("Слишком короткое видео", "Видео короче полсекунды, резать тут нечего.")
            }
            return VideoInfo(
                duration: duration,
                fps: frameRate > 0 ? Double(frameRate) : 30,
                width: Int(abs(oriented.width).rounded()),
                height: Int(abs(oriented.height).rounded()))
        } catch let error as AppError {
            throw error
        } catch {
            throw unreadable
        }
    }
}
