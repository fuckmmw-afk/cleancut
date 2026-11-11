import Foundation

/// Где лежат скачанные модели. В IPA их нет: всё качается при первом запуске.
enum ModelStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Models", isDirectory: true)
        prepare(url)
        return url
    }

    static var whisper: URL {
        let url = root.appendingPathComponent("whisper", isDirectory: true)
        prepare(url)
        return url
    }

    static var huggingFace: URL {
        let url = root.appendingPathComponent("hf", isDirectory: true)
        prepare(url)
        return url
    }

    /// Модели Silero VAD хранит сам FluidAudio.
    static var fluidAudio: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    private static func prepare(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Модели можно скачать заново, в резервную копию iCloud им не нужно.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    static func totalSize() -> Int64 {
        Disk.directorySize(root) + Disk.directorySize(fluidAudio)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: fluidAudio)
    }
}
