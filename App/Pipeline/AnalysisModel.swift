import CutCore
import Foundation
import Observation

/// Ведёт анализ по этапам: звук → VAD → Whisper → LLM. Живёт на главном потоке, тяжёлая работа уходит в фон.
@MainActor
@Observable
final class AnalysisModel {
    enum Step: Int, CaseIterable, Sendable {
        case audio, vad, whisper, llm

        var title: String {
            switch self {
            case .audio: "Достаю звук"
            case .vad: "Ищу паузы"
            case .whisper: "Распознаю речь"
            case .llm: "Ищу дубли"
            }
        }
    }

    enum State: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String, String)
    }

    private(set) var state: State = .idle
    private(set) var step: Step = .audio
    /// nil, если прогресс этапа неизвестен.
    private(set) var fraction: Double?
    private(set) var detail = ""
    private(set) var skippedSteps: Set<Step> = []

    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { state == .running }

    func start(projectID: UUID, store: ProjectStore, settings: PipelineSettings) {
        guard !isRunning, let project = store.project(projectID) else { return }
        state = .running
        skippedSteps = []
        BackgroundKeeper.shared.begin(title: "CleanCut: анализ видео")

        task = Task {
            var success = false
            do {
                try await run(project, store: store, settings: settings)
                state = .finished
                success = true
            } catch is CancellationError {
                state = .cancelled
            } catch {
                if Task.isCancelled {
                    state = .cancelled
                } else {
                    let appError = AppError.wrap(error, title: "Анализ не удался")
                    state = .failed(appError.title, appError.message)
                }
            }
            BackgroundKeeper.shared.end(success: success)
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Этапы

    private func enter(_ step: Step, detail: String = "", fraction: Double? = 0) {
        self.step = step
        self.detail = detail
        self.fraction = fraction
        publish()
    }

    private func update(_ step: Step, detail: String, fraction: Double?) {
        guard state == .running, self.step == step else { return }
        self.detail = detail
        self.fraction = fraction
        publish()
    }

    private func publish() {
        let overall = (Double(step.rawValue) + (fraction ?? 0)) / Double(Step.allCases.count)
        BackgroundKeeper.shared.update(progress: overall, subtitle: step.title)
    }

    private func run(_ original: Project, store: ProjectStore, settings: PipelineSettings) async throws {
        var project = original
        let sourceURL = ProjectStore.sourceURL(for: project)

        // Под временный звук, модели и служебные файлы.
        try Disk.ensure(300 << 20)

        if project.stage == .imported || project.words.isEmpty {
            let transcript = try await transcribe(sourceURL: sourceURL, settings: settings)
            project.words = transcript.words
            project.phrases = PhraseSegmenter.phrases(from: transcript.words)
            project.speech = transcript.speech
            project.notes = transcript.notes
            project.stage = .transcribed
            project.cuts = []
            // Сохраняем промежуточный результат: если приложение закроют, Whisper заново гонять не придётся.
            store.save(project)
        } else {
            skippedSteps = [.audio, .vad, .whisper]
        }
        try Task.checkCancellation()

        // Паузы.
        project.minPause = settings.minPause
        project.padding = settings.padding
        let options = settings.plannerOptions
        var cuts = CutPlanner.pauseCuts(speech: project.speech, duration: project.duration, options: options)
            .map { Cut(start: $0.start, end: $0.end, kind: .pause) }

        // Дубли.
        enter(.llm, detail: "", fraction: nil)
        let retakes = try await findRetakes(phrases: project.phrases, model: settings.retakeModel)
        project.notes.removeAll { $0.hasPrefix(Self.retakeNotePrefix) }
        project.notes.append(contentsOf: retakes.notes.map { Self.retakeNotePrefix + $0 })
        cuts += CutPlanner.retakeCuts(
            removals: retakes.removals, phrases: project.phrases, words: project.words,
            duration: project.duration, options: options)

        project.cuts = cuts.sorted { $0.start < $1.start }
        project.stage = .analyzed
        store.save(project)
    }

    /// Невидимый префикс, по которому замечания детектора дублей отличаются от остальных.
    private static let retakeNotePrefix = "\u{200B}"

    private struct Transcript: Sendable {
        var words: [Word]
        var speech: [TimeRange]
        var notes: [String]
    }

    private func transcribe(sourceURL: URL, settings: PipelineSettings) async throws -> Transcript {
        // 1. Звук.
        enter(.audio)
        let audioURL = AudioExtractor.temporaryURL()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audioProgress = ProgressThrottle { [weak self] value in
            self?.update(.audio, detail: "", fraction: value)
        }
        try await AudioExtractor.extract(from: sourceURL, to: audioURL) { audioProgress.report($0) }
        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioExtractor.loadSamples(from: audioURL)
        }.value
        try Task.checkCancellation()

        // 2. Речь и тишина.
        enter(.vad)
        let vadProgress = ProgressThrottle { [weak self] value in
            self?.update(.vad, detail: "", fraction: value)
        }
        let detection = try await SpeechDetector.detect(samples: samples, useSilero: settings.useSilero) {
            vadProgress.report($0)
        }
        var notes: [String] = []
        if let note = detection.note { notes.append(note) }
        try Task.checkCancellation()

        // 3. Транскрипция.
        enter(.whisper, detail: "Готовлю модель", fraction: nil)
        let modelTitle = settings.whisperModel.title
        let words = try await WhisperTranscriber.transcribe(samples: samples, model: settings.whisperModel) {
            [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .downloading(let value):
                    self?.update(
                        .whisper, detail: "Скачиваю \(modelTitle): \(Int(value * 100))%", fraction: value * 0.2)
                case .loading:
                    self?.update(.whisper, detail: "Загружаю модель. В первый раз это может занять пару минут", fraction: nil)
                case .transcribing(let value):
                    self?.update(.whisper, detail: "", fraction: 0.2 + value * 0.8)
                }
            }
        }
        guard !words.isEmpty else {
            throw AppError("Речь не найдена", "В этом видео не получилось распознать ни одного слова.")
        }
        return Transcript(words: words, speech: detection.speech, notes: notes)
    }

    private func findRetakes(phrases: [Phrase], model: RetakeModel) async throws -> RetakeOutcome {
        guard model != .off else {
            skippedSteps.insert(.llm)
            return RetakeOutcome(removals: [])
        }

        // Перебираем варианты от выбранного к более лёгким.
        var candidates: [RetakeModel]
        var notes: [String] = []
        switch model {
        case .qwen4B:
            candidates = [.qwen4B, .qwen1_7B, .heuristic]
            // Большой модели нужно около 3 ГБ. Если система столько не даст, сразу берём запасную.
            if MemoryBudget.available < 3_000 << 20 {
                candidates.removeFirst()
                notes.append("Для Qwen3-4B не хватило памяти, дубли искала запасная модель Qwen3-1.7B.")
            }
        case .qwen1_7B: candidates = [.qwen1_7B, .heuristic]
        default: candidates = [.heuristic]
        }

        var lastError: (any Error)?
        for candidate in candidates {
            guard let detector = RetakeDetectorFactory.make(candidate) else { continue }
            let title = candidate.title
            do {
                var outcome = try await detector.detect(phrases: phrases) { [weak self] phase in
                    Task { @MainActor in
                        switch phase {
                        case .downloading(let value):
                            self?.update(.llm, detail: "Скачиваю \(title): \(Int(value * 100))%", fraction: value * 0.2)
                        case .loading:
                            self?.update(.llm, detail: "Загружаю модель", fraction: nil)
                        case .analyzing(let value):
                            self?.update(.llm, detail: "", fraction: 0.2 + value * 0.8)
                        }
                    }
                }
                if candidate != model, candidate != .qwen1_7B || notes.isEmpty {
                    let reason = lastError.map { AppError.wrap($0).message } ?? ""
                    notes.append("«\(model.title)» не сработала, дубли искались вариантом «\(title)». \(reason)")
                }
                outcome.notes = notes + outcome.notes
                return outcome
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError ?? AppError("Дубли не найдены", "Не получилось запустить поиск дублей.")
    }
}
