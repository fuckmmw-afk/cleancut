import XCTest

@testable import CutCore

final class TranscriptCleanerTests: XCTestCase {
    private func words(_ text: String, from start: Double, step: Double = 0.4) -> [Word] {
        text.split(separator: " ").enumerated().map { index, part in
            Word(text: String(part), start: start + Double(index) * step, end: start + Double(index) * step + step * 0.9)
        }
    }

    func testRemovesContinuationHallucinationButKeepsRealWords() {
        // Из журнала: «И, конечно же, целых Продолжение следует...» — первые четыре слова настоящие.
        let input = words("И, конечно же, целых Продолжение следует...", from: 10)
        let result = TranscriptCleaner.clean(input, speech: [TimeRange(start: 10, end: 11.6)], duration: 60)
        XCTAssertEqual(result.words.map(\.text), ["И,", "конечно", "же,", "целых"])
        XCTAssertEqual(result.removed, ["Продолжение следует..."])
    }

    func testRemovesSubtitleCreditsSentence() {
        let input = words("Всем пока. Субтитры сделал DimaTorzok", from: 0)
        let result = TranscriptCleaner.clean(input, speech: [TimeRange(start: 0, end: 0.8)], duration: 10)
        XCTAssertEqual(result.words.map(\.text), ["Всем", "пока."])
    }

    func testWeakPatternKeptWhenSpoken() {
        let input = words("Спасибо за просмотр.", from: 5)
        let spoken = TranscriptCleaner.clean(input, speech: [TimeRange(start: 5, end: 6.2)], duration: 10)
        XCTAssertEqual(spoken.words.count, 3)
        let silent = TranscriptCleaner.clean(input, speech: [TimeRange(start: 0, end: 0.3)], duration: 10)
        XCTAssertTrue(silent.words.isEmpty)
    }

    func testDropsWordsPastEndOfVideo() {
        // Видео 4:30, а Whisper дописал слова на 4:53.
        let input = [Word(text: "конец.", start: 268, end: 269), Word(text: "Пока", start: 293, end: 294)]
        let result = TranscriptCleaner.clean(input, speech: [TimeRange(start: 267.8, end: 269.2)], duration: 270)
        XCTAssertEqual(result.words.map(\.text), ["конец."])
    }

    func testDropsZeroLengthWordsOnSilence() {
        let input = [
            Word(text: "раз", start: 1, end: 1.4), Word(text: "ага", start: 5, end: 5),
        ]
        let result = TranscriptCleaner.clean(input, speech: [TimeRange(start: 0.9, end: 1.5)], duration: 10)
        XCTAssertEqual(result.words.map(\.text), ["раз"])
    }

    func testMarksSpeechWithoutWords() {
        // Сказано «я я пошла», а Whisper написал «я пошла»: первое «я» осталось без слова.
        let input = [Word(text: "я", start: 1.6, end: 1.8), Word(text: "пошла", start: 1.85, end: 2.3)]
        let result = TranscriptCleaner.clean(input, speech: [TimeRange(start: 1.0, end: 2.35)], duration: 10)
        XCTAssertEqual(result.unknownCount, 1)
        XCTAssertEqual(result.words.first?.text, TranscriptCleaner.unknownText)
        XCTAssertEqual(result.words.first?.start ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.words.first?.end ?? 0, 1.54, accuracy: 1e-9)
        XCTAssertEqual(result.words.count, 3)
    }

    func testShortUncoveredPiecesIgnored() {
        let input = [Word(text: "привет", start: 1.1, end: 1.6)]
        let result = TranscriptCleaner.clean(input, speech: [TimeRange(start: 1.0, end: 1.75)], duration: 10)
        XCTAssertEqual(result.unknownCount, 0)
    }

    func testUnknownWordsDoNotBreakRepeatFinder() {
        let input = [
            Word(text: "мы", start: 0, end: 0.2), Word(text: "погово", start: 0.25, end: 0.6),
            Word(text: TranscriptCleaner.unknownText, start: 0.7, end: 1.2),
            Word(text: "мы", start: 1.3, end: 1.5), Word(text: "поговорим", start: 1.55, end: 2.1),
        ]
        let matches = RepeatFinder.restarts(in: input)
        XCTAssertEqual(matches.map(\.words), [0..<3])
    }
}
