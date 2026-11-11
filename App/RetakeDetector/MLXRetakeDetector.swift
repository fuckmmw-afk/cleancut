import CutCore
import Foundation
import HuggingFace
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Детектор дублей на локальной LLM через MLX Swift.
///
/// Модель видит транскрипт целиком (длинный — окнами с контекстом до и после), отвечает строго по JSON-схеме,
/// а каждое её решение потом проверяется по тексту в `RetakeValidator`.
struct MLXRetakeDetector: RetakeDetector {
    let modelID: String
    /// Сколько раз повторить запрос, если обычная генерация вернула кривой JSON.
    var maxRetries = 2

    func detect(
        phrases: [Phrase], log: AnalysisLog, onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> RetakeOutcome {
        guard !phrases.isEmpty else { return RetakeOutcome(removals: []) }

        // Буферы MLX не должны разрастаться: память нужна под веса.
        MLX.Memory.cacheLimit = 32 * 1024 * 1024

        let container = try await loadModel(log: log, onPhase: onPhase)
        defer { MLX.Memory.clearCache() }
        try Task.checkCancellation()
        log.memory("Модель загружена")

        let windows = RetakePrompt.windows(phrases)
        log.write("Фраз: \(phrases.count), окон: \(windows.count)")
        let grammar = await makeGrammarTokenizer(container: container, log: log)

        var results: [(window: RetakePrompt.Window, removals: [Removal])] = []
        var failed = 0
        for (index, window) in windows.enumerated() {
            onPhase(.analyzing(Double(index) / Double(windows.count)))
            if let removals = try await analyze(window, container: container, grammar: grammar, log: log) {
                results.append((window, removals))
            } else {
                failed += 1
            }
            MLX.Memory.clearCache()
        }
        onPhase(.analyzing(1))

        let suggested = RetakePrompt.mergeResults(results)
        let validation = RetakeValidator.validate(suggested, phrases: phrases)
        for item in validation.accepted {
            log.write("✓ \(item.id) \(item.reason.rawValue) → \(item.kept.map(String.init) ?? "-")")
        }
        for item in validation.rejected {
            log.write("✗ \(item.removal.id) \(item.removal.reason.rawValue) → \(item.removal.kept.map(String.init) ?? "-"): \(item.why)")
        }

        var notes: [String] = []
        if failed > 0 {
            notes.append(
                "Модель не справилась с \(failed) из \(windows.count) частей транскрипта: там дубли не искались. Проверь эти места вручную."
            )
        }
        if !validation.rejected.isEmpty {
            notes.append(
                "Ещё \(validation.rejected.count) предложений модели не подтвердились по тексту и не вырезаны. Они помечены «возможно дубль»: тапни, если с ними согласен."
            )
        }
        return RetakeOutcome(
            removals: validation.accepted,
            rejected: validation.rejected.map { RetakeOutcome.Rejection(removal: $0.removal, why: $0.why) },
            notes: notes)
    }

    // MARK: - Загрузка

    private func loadModel(
        log: AnalysisLog, onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> ModelContainer {
        let configuration = ModelConfiguration(id: modelID, extraEOSTokens: ["<|im_end|>"])
        var lastError: (any Error)?
        // Вторая попытка нужна, если первая упала на памяти или на повреждённом файле:
        // загрузчик сам проверяет файлы и докачивает испорченные.
        for attempt in 1...2 {
            onPhase(.downloading(0))
            log.memory("Загрузка \(modelID), попытка \(attempt)")
            do {
                return try await LLMModelFactory.shared.loadContainer(
                    from: HubDownloader(log: log),
                    using: TransformersTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { progress in
                        let fraction = progress.fractionCompleted
                        onPhase(fraction >= 1 ? .loading : .downloading(fraction))
                    })
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                lastError = error
                log.write("Ошибка загрузки: \(String(describing: error))")
                log.memory("После ошибки")
                MLX.Memory.clearCache()
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw AppError(
            "Языковая модель не загрузилась",
            "Не получилось загрузить \(modelID). \(AppError.wrap(lastError ?? CancellationError()).message)")
    }

    private func makeGrammarTokenizer(container: ModelContainer, log: AnalysisLog) async -> GrammarTokenizer? {
        do {
            return try await container.perform { context in
                let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                return try GrammarTokenizer(
                    vocab: vocab.vocab, vocabType: vocab.vocabType,
                    eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
            }
        } catch {
            log.write("Строгая схема недоступна, будет обычная генерация: \(error)")
            return nil
        }
    }

    // MARK: - Генерация

    /// - Returns: nil, если модель так и не вернула корректный JSON.
    private func analyze(
        _ window: RetakePrompt.Window, container: ModelContainer, grammar: GrammarTokenizer?, log: AnalysisLog
    ) async throws -> [Removal]? {
        let ids = window.ids
        let targets = window.targets
        log.write("Окно \(targets.first?.id ?? 0)–\(targets.last?.id ?? 0), контекст \(window.phrases.count) фраз")

        if let grammar {
            do {
                let response = try await guided(window, container: container, grammar: grammar)
                log.write("Ответ (схема): \(response)")
                if let removals = try? RetakeJSON.parse(response, allowedIDs: ids, maxRemovalShare: 1) {
                    return removals
                }
                log.write("Ответ по схеме не разобрался, пробую обычную генерацию")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                log.write("Генерация по схеме упала: \(String(describing: error))")
            }
        }

        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            try await ForegroundGate.waitUntilForeground()
            let response = try await plain(window, container: container, isRetry: attempt > 0)
            log.write("Ответ (попытка \(attempt + 1)): \(response)")
            if let removals = try? RetakeJSON.parse(response, allowedIDs: ids, maxRemovalShare: 1) {
                return removals
            }
        }
        return nil
    }

    private func chat(for window: RetakePrompt.Window, isRetry: Bool) -> UserInput {
        UserInput(
            chat: [.system(RetakePrompt.system), .user(RetakePrompt.user(for: window, isRetry: isRetry))],
            additionalContext: ["enable_thinking": false])
    }

    /// Генерация, ограниченная JSON-схемой: ответ всегда валидный, номера фраз только из окна.
    private func guided(
        _ window: RetakePrompt.Window, container: ModelContainer, grammar: GrammarTokenizer
    ) async throws -> String {
        try await ForegroundGate.waitUntilForeground()
        let schema = RetakePrompt.jsonSchema(for: window)
        let input = chat(for: window, isRetry: false)
        let cancelled = CancelFlag()
        let inputBox = UncheckedBox(input)
        return try await withTaskCancellationHandler {
            try await container.perform { context in
                let constraint = try GrammarConstraint(
                    tokenizer: grammar, jsonSchema: schema, fastForward: true, hostTokenizer: context.tokenizer)
                let prepared = try await context.processor.prepare(input: inputBox.value)
                var output = ""
                try GuidedGenerationLoop.run(
                    input: prepared, context: context, constraint: constraint, maxTokens: 1500,
                    vocabSize: grammar.vocabSize
                ) { delta in
                    output += delta
                    // GPU в фоне недоступен: ждём возврата на экран прямо здесь, на потоке генерации.
                    return ForegroundFlag.shared.waitBlocking(cancelled: cancelled)
                }
                if cancelled.isSet { throw CancellationError() }
                return output
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Обычная генерация через ChatSession, если схема недоступна.
    private func plain(_ window: RetakePrompt.Window, container: ModelContainer, isRetry: Bool) async throws -> String {
        let session = ChatSession(
            container,
            instructions: RetakePrompt.system,
            generateParameters: GenerateParameters(maxTokens: 1500, temperature: isRetry ? 0.4 : 0, topP: 0.9),
            additionalContext: ["enable_thinking": false])
        var response = ""
        for try await piece in session.streamResponse(to: RetakePrompt.user(for: window, isRetry: isRetry)) {
            response += piece
            try Task.checkCancellation()
            try await ForegroundGate.waitUntilForeground()
        }
        return response
    }
}

// MARK: - Мосты к загрузчику и токенайзеру Hugging Face

/// Скачивает веса с Hugging Face в каталог моделей приложения и проверяет, что файлы целые.
private struct HubDownloader: MLXLMCommon.Downloader {
    let log: AnalysisLog
    private let client = HubClient(cache: HubCache(cacheDirectory: ModelStore.huggingFace))

    init(log: AnalysisLog) {
        self.log = log
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw AppError("Неверная модель", "Не получилось разобрать идентификатор модели «\(id)».")
        }
        for attempt in 1...2 {
            let directory = try await client.downloadSnapshot(
                of: repoID,
                revision: revision ?? "main",
                matching: patterns,
                progressHandler: { @MainActor progress in
                    progressHandler(progress)
                })
            let broken = SafetensorsCheck.brokenFiles(in: directory)
            if broken.isEmpty {
                log.write("Файлы модели в порядке: \(SafetensorsCheck.describe(directory))")
                return directory
            }
            log.write("Повреждённые файлы модели (попытка \(attempt)): \(broken.map(\.lastPathComponent)), удаляю и качаю заново")
            for file in broken {
                // В кэше Hugging Face файл снимка — ссылка на blob. Удаляем и то и другое.
                let target = file.resolvingSymlinksInPath()
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.removeItem(at: file)
            }
        }
        throw AppError(
            "Модель скачалась с ошибкой",
            "Файл модели повреждён даже после повторной загрузки. Проверь свободное место и интернет и попробуй ещё раз.")
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
        let expected = 8 + headerLength + dataEnd
        let actual = UInt64(Disk.fileSize(resolved))
        return actual == expected
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
