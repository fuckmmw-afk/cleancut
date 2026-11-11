import CutCore
import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Детектор дублей на локальной LLM через MLX Swift.
struct MLXRetakeDetector: RetakeDetector {
    let modelID: String
    var chunkSize = 40
    var overlap = 8
    /// Сколько раз повторить запрос, если модель вернула кривой JSON.
    var maxRetries = 2

    func detect(
        phrases: [Phrase], onPhase: @escaping @Sendable (RetakePhase) -> Void
    ) async throws -> RetakeOutcome {
        guard !phrases.isEmpty else { return RetakeOutcome(removals: []) }

        // Буферы MLX не должны разрастаться: память нужна под веса.
        Memory.cacheLimit = 32 * 1024 * 1024

        onPhase(.downloading(0))
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: HubDownloader(),
                using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(id: modelID, extraEOSTokens: ["<|im_end|>"]),
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    onPhase(fraction >= 1 ? .loading : .downloading(fraction))
                })
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AppError.wrap(error, title: "Языковая модель не загрузилась")
        }
        defer { Memory.clearCache() }
        try Task.checkCancellation()

        let chunks = RetakePrompt.chunks(phrases, size: chunkSize, overlap: overlap)
        var results: [(chunk: RetakePrompt.Chunk, removals: [Removal])] = []
        var failed = 0

        for (index, chunk) in chunks.enumerated() {
            onPhase(.analyzing(Double(index) / Double(chunks.count)))
            if let removals = try await analyze(chunk, container: container) {
                results.append((chunk, removals))
            } else {
                failed += 1
            }
            Memory.clearCache()
        }
        onPhase(.analyzing(1))

        var notes: [String] = []
        if failed > 0 {
            notes.append(
                "Модель не справилась с \(failed) из \(chunks.count) кусков транскрипта: там дубли не искались. Проверь эти места вручную."
            )
        }
        return RetakeOutcome(removals: RetakePrompt.mergeResults(results), notes: notes)
    }

    /// - Returns: nil, если модель так и не вернула корректный JSON.
    private func analyze(_ chunk: RetakePrompt.Chunk, container: ModelContainer) async throws -> [Removal]? {
        let ids = chunk.ids
        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            try await ForegroundGate.waitUntilForeground()

            // Каждый запрос независим: история чата не копится и контекст не растёт.
            let session = ChatSession(
                container,
                instructions: RetakePrompt.system,
                generateParameters: GenerateParameters(
                    maxTokens: 900, temperature: attempt == 0 ? 0 : 0.4, topP: 0.9),
                additionalContext: ["enable_thinking": false])

            var response = ""
            do {
                for try await piece in session.streamResponse(to: RetakePrompt.user(for: chunk, isRetry: attempt > 0)) {
                    response += piece
                    try Task.checkCancellation()
                    try await ForegroundGate.waitUntilForeground()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                continue
            }

            if let removals = try? RetakeJSON.parse(response, allowedIDs: ids) {
                return removals
            }
        }
        return nil
    }
}

// MARK: - Мосты к загрузчику и токенайзеру Hugging Face

/// Скачивает веса с Hugging Face в каталог моделей приложения.
private struct HubDownloader: MLXLMCommon.Downloader {
    private let client = HubClient(cache: HubCache(cacheDirectory: ModelStore.huggingFace))

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
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            })
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
