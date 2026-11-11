import CutCore
import Foundation

/// Модель, которую можно скачать в настройках.
enum ModelKind: Hashable, Sendable, Identifiable {
    case silero
    case whisper(WhisperModel)
    case llm(RetakeModel)

    static let all: [ModelKind] =
        [.silero] + WhisperModel.allCases.map(ModelKind.whisper)
        + RetakeModel.allCases.filter(\.isLLM).map(ModelKind.llm)

    var id: String {
        switch self {
        case .silero: "silero"
        case .whisper(let model): "whisper:" + model.rawValue
        case .llm(let model): "llm:" + model.rawValue
        }
    }

    var title: String {
        switch self {
        case .silero: "Silero VAD"
        case .whisper(let model): "Whisper \(model.title)"
        case .llm(let model): model.title
        }
    }

    var purpose: String {
        switch self {
        case .silero: "паузы"
        case .whisper: "распознавание речи"
        case .llm: "поиск дублей"
        }
    }

    /// Примерный размер на диске.
    var estimatedSize: Int64 {
        switch self {
        case .silero: 2 << 20
        case .whisper(.largeV3Turbo): 640 << 20
        case .whisper(.small): 500 << 20
        case .whisper(.base): 155 << 20
        case .llm(.qwen4B): 2_290 << 20
        case .llm(.qwen1_7B): 1_000 << 20
        case .llm: 0
        }
    }
}

/// Где лежат скачанные модели. Работает с любого потока и никогда не ходит в сеть.
enum ModelLocator {
    private static var manifestURL: URL { ModelStore.root.appendingPathComponent("installed.json") }

    private static func manifest() -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: manifestURL) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Пути хранятся относительно каталога моделей: путь к контейнеру приложения меняется после переустановки.
    static func record(_ kind: ModelKind, folder: URL?) {
        var entries = manifest()
        if let folder {
            let rootPath = ModelStore.root.standardizedFileURL.path + "/"
            let path = folder.standardizedFileURL.path
            entries[kind.id] = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        } else {
            entries[kind.id] = nil
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private static func recorded(_ kind: ModelKind) -> URL? {
        guard let path = manifest()[kind.id] else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : ModelStore.root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Silero

    static var sileroFile: URL {
        ModelStore.fluidAudio.appendingPathComponent("Models/silero-vad-coreml", isDirectory: true)
            .appendingPathComponent("silero-vad-unified-256ms-v6.2.1.mlmodelc")
    }

    static var isSileroInstalled: Bool {
        FileManager.default.fileExists(atPath: sileroFile.path)
    }

    // MARK: Whisper

    static func whisperFolder(_ model: WhisperModel) -> URL? {
        guard let folder = recorded(.whisper(model)) else { return nil }
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        let complete = required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return complete ? folder : nil
    }

    // MARK: LLM

    static func llmFolder(_ model: RetakeModel) -> URL? {
        guard model.isLLM, let folder = recorded(.llm(model)) else { return nil }
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.appendingPathComponent("config.json").path),
            manager.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path)
        else { return nil }
        let weights = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "safetensors" }
        return weights.isEmpty ? nil : folder
    }

    // MARK: Общее

    static func isInstalled(_ kind: ModelKind) -> Bool {
        switch kind {
        case .silero: isSileroInstalled
        case .whisper(let model): whisperFolder(model) != nil
        case .llm(let model): llmFolder(model) != nil
        }
    }

    /// Каталог, который занимает модель (для подсчёта размера и удаления).
    static func storage(_ kind: ModelKind) -> URL? {
        let url: URL
        switch kind {
        case .silero:
            url = sileroFile
        case .whisper(let model):
            guard let folder = recorded(.whisper(model)) else { return nil }
            url = folder
        case .llm(let model):
            // Вместе с blob-файлами кэша Hugging Face.
            let name = "models--" + model.rawValue.replacingOccurrences(of: "/", with: "--")
            url = ModelStore.huggingFace.appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func size(_ kind: ModelKind) -> Int64 {
        guard let url = storage(kind) else { return 0 }
        return Disk.directorySize(url)
    }
}

/// Проверка целостности safetensors: размер файла должен совпадать с тем, что записано в его заголовке.
enum SafetensorsCheck {
    static func brokenFiles(in directory: URL) -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" && !isComplete($0) }
    }

    static func describe(_ directory: URL) -> String {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" }
            .map { "\($0.lastPathComponent) \(Format.bytes(Disk.fileSize($0.resolvingSymlinksInPath())))" }
            .joined(separator: ", ")
    }

    static func isComplete(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return false }
        defer { try? handle.close() }
        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else { return false }
        let headerLength = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard headerLength > 0, headerLength < 100_000_000,
            let headerData = try? handle.read(upToCount: Int(headerLength)), headerData.count == Int(headerLength),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return false }

        var dataEnd: UInt64 = 0
        for (name, value) in header where name != "__metadata__" {
            guard let entry = value as? [String: Any], let offsets = entry["data_offsets"] as? [NSNumber],
                offsets.count == 2
            else { return false }
            dataEnd = max(dataEnd, offsets[1].uint64Value)
        }
        return UInt64(Disk.fileSize(resolved)) == 8 + headerLength + dataEnd
    }
}
