import CutCore
import HuggingFace
import MLXGuidedGeneration
import MLXLMCommon
import XCTest

@testable import CleanCut

/// Проверка без запуска LLM (MLX на симуляторе не работает): токенайзер Qwen3 скачивается,
/// шаблон чата собирается с выключенным «размышлением», а JSON-схема компилируется в грамматику.
final class RetakeGrammarTests: XCTestCase {

    func testSchemaCompilesForQwenTokenizer() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hf-test", isDirectory: true)
        let client = HubClient(cache: HubCache(cacheDirectory: cache))
        let repo = try XCTUnwrap(Repo.ID(rawValue: "mlx-community/Qwen3-4B-Instruct-2507-4bit"))
        let directory = try await client.downloadSnapshot(
            of: repo, matching: ["*.json", "merges.txt", "*.jinja"])

        let tokenizer = try await TransformersTokenizerLoader().load(from: directory)

        let phrases = (1...130).map {
            Phrase(id: $0, start: Double($0), end: Double($0) + 0.5, text: "фраза \($0)", firstWord: $0 - 1, wordCount: 1)
        }
        let windows = RetakePrompt.windows(phrases)
        XCTAssertEqual(windows.count, 3)

        // Шаблон чата: system + user, без блока размышлений.
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": RetakePrompt.system],
            ["role": "user", "content": RetakePrompt.user(for: windows[1])],
        ]
        let tokens = try tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
        let rendered = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        XCTAssertTrue(rendered.contains("Ты опытный монтажёр"))
        XCTAssertTrue(rendered.contains("51 [00:51.0–00:51.5] фраза 51"))
        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n"), String(rendered.suffix(80)))
        print("PROMPT TOKENS: \(tokens.count)")

        let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
        let grammar = try GrammarTokenizer(
            vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
        XCTAssertGreaterThan(grammar.vocabSize, 150_000)
        for window in windows {
            _ = try GrammarConstraint(
                tokenizer: grammar, jsonSchema: RetakePrompt.jsonSchema(for: window), fastForward: true,
                hostTokenizer: tokenizer)
        }
    }
}
