import XCTest

@testable import CutCore

final class RetakeValidatorTests: XCTestCase {

    func makePhrases(_ texts: [String]) -> [Phrase] {
        texts.enumerated().map { index, text in
            Phrase(
                id: index + 1, start: Double(index) * 3, end: Double(index) * 3 + 2.5, text: text,
                firstWord: index, wordCount: 1)
        }
    }

    lazy var phrases = makePhrases([
        "Всем привет, сегодня",  // 1
        "Так, стоп, ещё раз.",  // 2
        "Всем привет, сегодня расскажу про монтаж на айфоне.",  // 3
        "Первое, что нужно сделать, это включить",  // 4
        "Первое, что нужно сделать, это включить авиарежим.",  // 5
        "Он нужен, чтобы уведомления не мешали записи.",  // 6
        "Уведомления правда очень мешают.",  // 7
        "Второе: выставляем свет.",  // 8
        "Лучше всего ставить лампу сбоку от лица.",  // 9
        "Подписывайтесь на канал.",  // 10
    ])

    func validate(_ removals: [Removal]) -> RetakeValidator.Result {
        RetakeValidator.validate(removals, phrases: phrases)
    }

    func testAcceptsRealRetakes() {
        let result = validate([
            Removal(id: 1, reason: .falseStart, kept: 3),
            Removal(id: 2, reason: .garbage),
            Removal(id: 4, reason: .retake, kept: 5),
        ])
        XCTAssertEqual(result.accepted.map(\.id), [1, 2, 4])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testRejectsContinuationOfThought() {
        // «Уведомления правда очень мешают» продолжает мысль, а не повторяет фразу 6.
        let result = validate([
            Removal(id: 6, reason: .retake, kept: 7),
            Removal(id: 8, reason: .retake, kept: 9),
        ])
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected.map(\.removal.id), [6, 8])
    }

    func testRejectsMissingOrBackwardReplacement() {
        let result = validate([
            Removal(id: 9, reason: .retake),
            Removal(id: 5, reason: .retake, kept: 4),
            Removal(id: 3, reason: .retake, kept: 3),
        ])
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected.count, 3)
    }

    func testRejectsFarReplacement() {
        var options = RetakeValidator.Options()
        options.maxPhraseDistance = 3
        let result = RetakeValidator.validate(
            [Removal(id: 1, reason: .retake, kept: 9)], phrases: phrases, options: options)
        XCTAssertTrue(result.accepted.isEmpty)
    }

    func testGarbageRules() {
        let result = validate([
            Removal(id: 10, reason: .garbage),  // нормальная фраза без маркеров
            Removal(id: 2, reason: .garbage),  // служебная реплика
        ])
        XCTAssertEqual(result.accepted.map(\.id), [2])
        XCTAssertEqual(result.rejected.map(\.removal.id), [10])
    }

    func testShortFillerFalseStart() {
        let short = makePhrases(["Ну вот", "Ну вот, продолжаем разговор про свет."])
        let result = RetakeValidator.validate([Removal(id: 1, reason: .falseStart, kept: 2)], phrases: short)
        XCTAssertEqual(result.accepted.map(\.id), [1])
    }

    func testRetakeSplitAcrossTwoPhrases() {
        let split = makePhrases([
            "Сегодня я покажу три способа монтажа",
            "Сегодня я покажу",
            "три способа монтажа прямо на телефоне.",
        ])
        let result = RetakeValidator.validate([Removal(id: 1, reason: .retake, kept: 2)], phrases: split)
        XCTAssertEqual(result.accepted.map(\.id), [1])
    }

    func testCoverageIgnoresStopWordsAndEndings() {
        XCTAssertEqual(RetakeValidator.coverage(of: "это про монтаж", in: "расскажу о монтаже"), 1)
        XCTAssertEqual(RetakeValidator.coverage(of: "и вот", in: "что угодно"), 0)
    }
}
