import XCTest

@testable import CutCore

final class SegmenterAndVADTests: XCTestCase {

    func testSanitize() {
        let words = PhraseSegmenter.sanitize([
            Word(text: " Привет", start: 0, end: 0.4),
            Word(text: ",", start: 0.4, end: 0.4),
            Word(text: "  ", start: 0.5, end: 0.6),
            Word(text: "<|endoftext|>", start: 0.6, end: 0.7),
            Word(text: " мир.", start: 0.9, end: 0.7),
        ])
        XCTAssertEqual(words.map(\.text), ["Привет,", "мир."])
        XCTAssertEqual(words[1].end, 0.9)
    }

    func testSplitByPunctuationAndGap() {
        let words = [
            Word(text: "Привет", start: 0, end: 0.3), Word(text: "всем.", start: 0.35, end: 0.7),
            Word(text: "Сегодня", start: 0.8, end: 1.2), Word(text: "мы", start: 1.25, end: 1.4),
            Word(text: "Сегодня", start: 2.4, end: 2.8), Word(text: "поговорим", start: 2.85, end: 3.4),
        ]
        let phrases = PhraseSegmenter.phrases(from: words)
        XCTAssertEqual(phrases.map(\.text), ["Привет всем.", "Сегодня мы", "Сегодня поговорим"])
        XCTAssertEqual(phrases.map(\.id), [1, 2, 3])
        XCTAssertEqual(phrases[1].wordRange, 2..<4)
        XCTAssertEqual(phrases[2].start, 2.4)
        XCTAssertEqual(phrases[2].end, 3.4)
        XCTAssertEqual(phrases.map(\.wordCount).reduce(0, +), words.count)
    }

    func testLongPhraseIsSplit() {
        let words = (0..<100).map {
            Word(text: $0 % 10 == 9 ? "слово," : "слово", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25)
        }
        let phrases = PhraseSegmenter.phrases(from: words)
        XCTAssertGreaterThan(phrases.count, 2)
        XCTAssertTrue(phrases.allSatisfy { $0.wordCount <= 40 })
        XCTAssertEqual(phrases.map(\.wordCount).reduce(0, +), 100)
    }

    func testEnergyVADFindsSpeech() {
        let rate = 16000.0
        var samples = [Float](repeating: 0, count: Int(rate * 3))
        // Слабый шум везде и «речь» с 1.0 до 2.0 с.
        var seed: UInt32 = 12345
        for index in samples.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.002
            let time = Double(index) / rate
            let voice: Float = time >= 1.0 && time < 2.0 ? 0.3 * Float(sin(2 * Double.pi * 220 * time)) : 0
            samples[index] = noise + voice
        }
        let ranges = EnergyVAD.speechRanges(samples: samples, sampleRate: rate)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 1.0, accuracy: 0.03)
        XCTAssertEqual(ranges[0].end, 2.0, accuracy: 0.03)
    }

    func testEnergyVADJoinsShortDips() {
        let levels: [Float] = Array(repeating: -60, count: 20) + Array(repeating: -20, count: 20)
            + Array(repeating: -60, count: 5) + Array(repeating: -20, count: 20) + Array(repeating: -60, count: 30)
        let ranges = EnergyVAD.speechRanges(levels: levels, frameDuration: 0.02, options: .init())
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end, 1.3, accuracy: 1e-9)
    }

    func testHeuristicRetakes() {
        func phrase(_ id: Int, _ text: String) -> Phrase {
            Phrase(id: id, start: Double(id), end: Double(id) + 0.5, text: text, firstWord: 0, wordCount: 1)
        }
        let removals = HeuristicRetake.detect([
            phrase(1, "Привет, сегодня мы поговорим о"),
            phrase(2, "Бля, ещё раз."),
            phrase(3, "Привет, сегодня мы поговорим о монтаже."),
            phrase(4, "Это очень важная тема."),
            phrase(5, "Первое, что нужно"),
            phrase(6, "Первое, что нужно сделать, это включить камеру."),
        ])
        XCTAssertEqual(
            removals,
            [
                Removal(id: 1, reason: .falseStart), Removal(id: 2, reason: .garbage),
                Removal(id: 5, reason: .falseStart),
            ])
    }
}

final class SpeechSegmenterTests: XCTestCase {
    func testCoarseHysteresis() {
        let probs: [Float] = [0.1, 0.7, 0.5, 0.45, 0.2, 0.1, 0.9, 0.9]
        let ranges = SpeechSegmenter.coarseRanges(probabilities: probs, hop: 0.25)
        XCTAssertEqual(ranges, [TimeRange(start: 0.25, end: 1.0), TimeRange(start: 1.5, end: 2.0)])
    }

    func testEnergyRefinesBoundaries() {
        // Окна по 0.25 с, речь по Silero в окнах 1..<3 (0.25–0.75 с).
        let probs: [Float] = [0.1, 0.9, 0.9, 0.1, 0.1, 0.1]
        // По энергии речь на самом деле идёт с 0.34 до 0.82 с (кадры 17..<41 по 20 мс).
        var levels = [Float](repeating: -60, count: 75)
        for index in 17..<41 { levels[index] = -20 }
        let ranges = SpeechSegmenter.speechRanges(
            probabilities: probs, hop: 0.25, levels: levels, frameDuration: 0.02, duration: 1.5)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0.34, accuracy: 1e-6)
        XCTAssertEqual(ranges[0].end, 0.82, accuracy: 1e-6)
    }

    func testFallsBackToCoarseWithoutLevels() {
        let ranges = SpeechSegmenter.speechRanges(
            probabilities: [0.9, 0.9, 0.1], hop: 0.25, levels: [], frameDuration: 0.02, duration: 0.6)
        XCTAssertEqual(ranges, [TimeRange(start: 0, end: 0.5)])
    }
}
