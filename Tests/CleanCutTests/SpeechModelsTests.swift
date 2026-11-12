import CutCore
import XCTest

@testable import CleanCut

/// Проверка на настоящих моделях: Silero VAD и Whisper base скачиваются с Hugging Face и разбирают
/// русскую речь, которую CI синтезирует командой `say` (Fixtures/speech.wav).
final class SpeechModelsTests: XCTestCase {

    /// Скачивает модель тем же путём, что и кнопка в настройках.
    @MainActor
    private static func install(_ kind: ModelKind) async throws {
        let manager = ModelManager()
        if manager.isInstalled(kind) { return }
        manager.install(kind)
        while case .working = manager.status(kind) {
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(manager.isInstalled(kind), "\(manager.status(kind))")
        XCTAssertTrue(ModelLocator.isInstalled(kind))
    }

    private func loadSpeech() async throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "speech", withExtension: "wav"),
            "нет Fixtures/speech.wav: его создаёт шаг CI перед сборкой")
        let rawURL = AudioExtractor.temporaryURL()
        defer { try? FileManager.default.removeItem(at: rawURL) }
        try await AudioExtractor.extract(from: url, to: rawURL) { _ in }
        return try AudioExtractor.loadSamples(from: rawURL)
    }

    func testSileroFindsSpeechAndThePause() async throws {
        try await Self.install(.silero)
        let samples = try await loadSpeech()
        let duration = Double(samples.count) / 16000
        let detection = try await SpeechDetector.detect(samples: samples, useSilero: true) { _ in }
        XCTAssertTrue(detection.usedSilero, detection.note ?? "")
        XCTAssertGreaterThanOrEqual(detection.speech.count, 2, "\(detection.speech)")

        // Между двумя дублями в записи вставлено 1.5 с тишины.
        let pauses = CutPlanner.pauseCuts(speech: detection.speech, duration: duration, options: .init())
        XCTAssertTrue(pauses.contains { $0.duration > 0.8 && $0.start > 1 && $0.end < duration - 1 }, "\(pauses)")
        let speechTotal = detection.speech.reduce(0) { $0 + $1.duration }
        XCTAssertGreaterThan(speechTotal, duration * 0.4)
    }

    func testWhisperGivesWordTimestamps() async throws {
        try await Self.install(.whisper(.base))
        let samples = try await loadSpeech()
        let duration = Double(samples.count) / 16000
        let words = try await WhisperTranscriber.transcribe(samples: samples, model: .base) { _ in }
        let text = words.map(\.text).joined(separator: " ").lowercased()
        print("WHISPER TEXT: \(text)")
        XCTAssertTrue(text.contains("привет"), text)
        XCTAssertTrue(text.contains("монтаж"), text)

        XCTAssertGreaterThan(words.count, 8)
        for (previous, next) in zip(words, words.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.start, next.start)
        }
        XCTAssertTrue(words.allSatisfy { $0.start >= 0 && $0.end <= duration + 0.5 && $0.end >= $0.start })

        // Фраза произнесена дважды: «привет» должен встретиться в начале и после паузы.
        let greetings = words.filter { $0.text.lowercased().contains("привет") }
        XCTAssertEqual(greetings.count, 2, text)
        if greetings.count == 2 {
            XCTAssertGreaterThan(greetings[1].start - greetings[0].start, 2.5)
        }

        let phrases = PhraseSegmenter.phrases(from: words)
        XCTAssertGreaterThanOrEqual(phrases.count, 2)
        print("PHRASES: \(phrases.map { "\($0.id) [\($0.start)-\($0.end)] \($0.text)" })")
        print("HEURISTIC: \(HeuristicRetake.detect(phrases))")
    }
}

final class ModelManagerTests: XCTestCase {
    @MainActor
    func testMissingModelsFollowSettings() {
        let manager = ModelManager()
        let settings = PipelineSettings(
            minPause: 0.5, padding: 0.12, tailPadding: 0.05, whisperModel: .base, retakeModel: .heuristic, useSilero: false)
        let missing = manager.missing(for: settings, needsTranscription: false)
        XCTAssertTrue(missing.isEmpty, "\(missing)")

        var withLLM = settings
        withLLM.retakeModel = .qwen1_7B
        if !ModelLocator.isInstalled(.llm(.qwen1_7B)) {
            XCTAssertEqual(manager.missing(for: withLLM, needsTranscription: false), [.llm(.qwen1_7B)])
        }
    }
}
