import FluidAudio
import Foundation
import HuggingFace
import Observation
@preconcurrency import WhisperKit

/// Скачивание и удаление моделей. Всё, что нужно для обработки, скачивается здесь один раз.
@MainActor
@Observable
final class ModelManager {
    enum Status: Equatable {
        case notInstalled
        case installed(Int64)
        /// nil, если прогресс этапа неизвестен.
        case working(Double?, String)
        case failed(String)
    }

    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        // Синхронно: проверка — это несколько обращений к диску, а экрану обработки статус нужен сразу.
        for kind in ModelKind.all {
            statuses[kind.id] = ModelLocator.isInstalled(kind) ? .installed(ModelLocator.size(kind)) : .notInstalled
        }
    }

    func status(_ kind: ModelKind) -> Status {
        statuses[kind.id] ?? .notInstalled
    }

    func isInstalled(_ kind: ModelKind) -> Bool {
        if case .installed = status(kind) { return true }
        return false
    }

    var isBusy: Bool { !tasks.isEmpty }

    var totalSize: Int64 {
        statuses.values.reduce(0) { total, status in
            if case .installed(let size) = status { return total + size }
            return total
        }
    }

    /// Перечитывает с диска, что установлено. Размеры считаются в фоне.
    func refresh() {
        Task {
            let result = await Task.detached(priority: .utility) {
                ModelKind.all.map { kind in
                    (kind.id, ModelLocator.isInstalled(kind) ? ModelLocator.size(kind) : nil)
                }
            }.value
            for (id, size) in result where tasks[id] == nil {
                statuses[id] = size.map { .installed($0) } ?? .notInstalled
            }
        }
    }

    /// Модели, без которых нельзя начать обработку с текущими настройками.
    func missing(for settings: PipelineSettings, needsTranscription: Bool) -> [ModelKind] {
        var required: [ModelKind] = []
        if needsTranscription { required.append(.whisper(settings.whisperModel)) }
        if settings.retakeModel.isLLM { required.append(.llm(settings.retakeModel)) }
        return required.filter { !isInstalled($0) }
    }

    // MARK: - Скачивание

    func install(_ kind: ModelKind) {
        guard tasks[kind.id] == nil else { return }
        statuses[kind.id] = .working(0, "Подготовка")
        BackgroundKeeper.shared.begin(title: "CleanCut: скачивание моделей")

        tasks[kind.id] = Task {
            var success = false
            do {
                try Disk.ensure(kind.estimatedSize + (kind.estimatedSize / 5) + (200 << 20))
                try await perform(kind)
                let size = await Task.detached { ModelLocator.size(kind) }.value
                statuses[kind.id] = .installed(size)
                success = true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    statuses[kind.id] = ModelLocator.isInstalled(kind) ? .installed(ModelLocator.size(kind)) : .notInstalled
                } else {
                    statuses[kind.id] = .failed(AppError.wrap(error, title: "Модель не скачалась").message)
                }
            }
            tasks[kind.id] = nil
            BackgroundKeeper.shared.end(success: success)
        }
    }

    func cancel(_ kind: ModelKind) {
        tasks[kind.id]?.cancel()
    }

    func delete(_ kind: ModelKind) {
        guard tasks[kind.id] == nil else { return }
        if let url = ModelLocator.storage(kind) {
            try? FileManager.default.removeItem(at: url)
        }
        ModelLocator.record(kind, folder: nil)
        statuses[kind.id] = .notInstalled
    }

    func deleteAll() {
        for task in tasks.values { task.cancel() }
        ModelStore.deleteAll()
        refresh()
    }

    private func update(_ kind: ModelKind, _ fraction: Double?, _ text: String) {
        guard tasks[kind.id] != nil else { return }
        statuses[kind.id] = .working(fraction, text)
        if let fraction { BackgroundKeeper.shared.update(progress: fraction, subtitle: kind.title) }
    }

    /// Передаёт прогресс из фоновых колбэков на главный поток.
    private func reporter(_ kind: ModelKind, _ text: String, scale: ClosedRange<Double> = 0...1)
        -> ProgressThrottle
    {
        ProgressThrottle(interval: .milliseconds(200)) { [weak self] value in
            self?.update(kind, scale.lowerBound + value * (scale.upperBound - scale.lowerBound), text)
        }
    }

    private nonisolated static func prepareWhisper(folder: URL) async throws {
        let config = WhisperKitConfig(
            downloadBase: ModelStore.whisper,
            modelFolder: folder.path,
            tokenizerFolder: ModelStore.whisper,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false)
        nonisolated(unsafe) let whisper = try await WhisperKit(config)
        await whisper.unloadModels()
    }

    private func perform(_ kind: ModelKind) async throws {
        switch kind {
        case .silero:
            let progress = reporter(kind, "Скачиваю")
            _ = try await VadManager(config: VadConfig()) { progress.report($0.fractionCompleted) }
            guard ModelLocator.isSileroInstalled else {
                throw AppError("Silero VAD не скачался", "Файл модели не появился после загрузки.")
            }

        case .whisper(let model):
            let progress = reporter(kind, "Скачиваю", scale: 0...0.85)
            let folder = try await WhisperKit.download(
                variant: model.rawValue,
                downloadBase: ModelStore.whisper,
                progressCallback: { progress.report($0.fractionCompleted) })
            try Task.checkCancellation()

            // Первая загрузка компилирует модель под Neural Engine и скачивает токенайзер.
            // Делаем это здесь, чтобы обработка видео потом работала без сети и без долгой паузы.
            update(kind, nil, "Готовлю модель для Neural Engine, это может занять пару минут")
            try await Self.prepareWhisper(folder: folder)
            ModelLocator.record(kind, folder: folder)

        case .llm(let model):
            let client = HubClient(cache: HubCache(cacheDirectory: ModelStore.huggingFace))
            guard let repo = Repo.ID(rawValue: model.rawValue) else {
                throw AppError("Неверная модель", "Не получилось разобрать идентификатор «\(model.rawValue)».")
            }
            for attempt in 1...2 {
                let progress = reporter(kind, attempt == 1 ? "Скачиваю" : "Докачиваю повреждённый файл")
                let folder = try await client.downloadSnapshot(
                    of: repo, matching: ["*.safetensors", "*.json", "*.jinja"],
                    progressHandler: { @MainActor value in progress.report(value.fractionCompleted) })
                try Task.checkCancellation()
                update(kind, nil, "Проверяю файлы")
                let broken = await Task.detached { SafetensorsCheck.brokenFiles(in: folder) }.value
                if broken.isEmpty {
                    ModelLocator.record(kind, folder: folder)
                    return
                }
                for file in broken {
                    // В кэше Hugging Face файл снимка — ссылка на blob. Удаляем и то и другое.
                    try? FileManager.default.removeItem(at: file.resolvingSymlinksInPath())
                    try? FileManager.default.removeItem(at: file)
                }
            }
            throw AppError(
                "Модель скачалась с ошибкой",
                "Файл модели повреждён даже после повторной загрузки. Проверь свободное место и интернет и попробуй ещё раз."
            )
        }
    }
}
