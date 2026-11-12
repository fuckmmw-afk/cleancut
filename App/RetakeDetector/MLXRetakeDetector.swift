import CutCore
import Foundation
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
    let model: RetakeModel
    var modelID: String { model.rawValue }
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
        let grammar = await makeGrammar(container: container, log: log)

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
        guard let folder = ModelLocator.llmFolder(model) else {
            throw AppError(
                "Модель не скачана", "\(model.title) не скачана. Открой Настройки → Модели и скачай её.")
        }
        let broken = SafetensorsCheck.brokenFiles(in: folder)
        log.write("Файлы модели: \(SafetensorsCheck.describe(folder))")
        guard broken.isEmpty else {
            throw AppError(
                "Файл модели повреждён",
                "\(model.title) скачалась не полностью. Удали её в Настройки → Модели и скачай заново.")
        }

        let configuration = ModelConfiguration(id: modelID, extraEOSTokens: ["<|im_end|>"])
        var lastError: (any Error)?
        // Вторая попытка нужна, если первая упала из-за нехватки памяти.
        for attempt in 1...2 {
            onPhase(.loading)
            log.memory("Загрузка \(modelID), попытка \(attempt)")
            do {
                return try await LLMModelFactory.shared.loadContainer(
                    from: LocalModelDownloader(folder: folder),
                    using: TransformersTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { _ in onPhase(.loading) })
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

    /// Токенайзер грамматики и штрафы, которые не дают модели тратить токены на пробелы и не закрывать JSON.
    private struct Grammar: @unchecked Sendable {
        let tokenizer: GrammarTokenizer
        let closingBias: MLXArray
        let whitespaceBias: MLXArray
        let whitespaceTokenIDs: Set<Int>
    }

    private func makeGrammar(container: ModelContainer, log: AnalysisLog) async -> Grammar? {
        do {
            let box = try await container.perform { context in
                let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                let tokenizer = try GrammarTokenizer(
                    vocab: vocab.vocab, vocabType: vocab.vocabType,
                    eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
                let closing = ClosingTokenBias.compute(
                    tokenizer: context.tokenizer, eosTokenId: context.tokenizer.eosTokenId)
                let whitespace = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)
                return UncheckedBox(
                    Grammar(
                        tokenizer: tokenizer, closingBias: closing, whitespaceBias: whitespace.bias,
                        whitespaceTokenIDs: whitespace.tokenIDs))
            }
            return box.value
        } catch {
            log.write("Строгая схема недоступна, будет обычная генерация: \(error)")
            return nil
        }
    }

    // MARK: - Генерация

    /// - Returns: nil, если модель так и не вернула корректный JSON.
    private func analyze(
        _ window: RetakePrompt.Window, container: ModelContainer, grammar: Grammar?, log: AnalysisLog
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
        _ window: RetakePrompt.Window, container: ModelContainer, grammar: Grammar
    ) async throws -> String {
        try await ForegroundGate.waitUntilForeground()
        let schema = RetakePrompt.jsonSchema(for: window)
        let input = chat(for: window, isRetry: false)
        let cancelled = CancelFlag()
        let inputBox = UncheckedBox(input)
        let grammarBox = UncheckedBox(grammar)
        return try await withTaskCancellationHandler {
            try await container.perform { context in
                let grammar = grammarBox.value
                let constraint = try GrammarConstraint(
                    tokenizer: grammar.tokenizer, jsonSchema: schema, fastForward: true,
                    hostTokenizer: context.tokenizer)
                let prepared = try await context.processor.prepare(input: inputBox.value)
                var output = ""
                try GuidedGenerationLoop.run(
                    input: prepared, context: context, constraint: constraint, maxTokens: 1500,
                    vocabSize: grammar.tokenizer.vocabSize,
                    completionReserve: 64,
                    closingBias: grammar.closingBias,
                    whitespaceBias: grammar.whitespaceBias,
                    whitespaceTokenIDs: grammar.whitespaceTokenIDs
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

/// Отдаёт загрузчику MLX уже скачанную модель. В сеть не ходит: модели скачиваются в настройках.
private struct LocalModelDownloader: MLXLMCommon.Downloader {
    let folder: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        progressHandler(progress)
        return folder
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
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
