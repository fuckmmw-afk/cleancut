import XCTest

@testable import CutCore

final class RepeatFinderTests: XCTestCase {

    /// Слова с таймкодами по 0.4 с; «|» в строке начинает новую фразу после паузы в 1 с.
    func transcript(_ text: String) -> (words: [Word], phrases: [Phrase]) {
        var words: [Word] = []
        var time = 0.0
        for part in text.split(separator: " ") {
            if part == "|" {
                time += 1
                continue
            }
            words.append(Word(text: String(part), start: time, end: time + 0.35))
            time += 0.4
        }
        return (words, PhraseSegmenter.phrases(from: words))
    }

    func cutText(_ text: String) -> String {
        let (words, phrases) = transcript(text)
        let matches = RepeatFinder.find(words: words, phrases: phrases)
        var cut = IndexSet()
        for match in matches { cut.insert(integersIn: match.words) }
        return words.indices.filter { !cut.contains($0) }.map { words[$0].text }.joined(separator: " ")
    }

    // MARK: Внутри предложения

    func testStutter() {
        XCTAssertEqual(cutText("я я пошёл домой."), "я пошёл домой.")
        XCTAssertEqual(cutText("это, это важно."), "это важно.")
        XCTAssertEqual(cutText("ну, ну и что дальше?"), "ну и что дальше?")
    }

    func testTruncatedWordRestart() {
        XCTAssertEqual(cutText("мы погово, мы поговорим о монтаже."), "мы поговорим о монтаже.")
    }

    func testRestartInsideSentence() {
        XCTAssertEqual(
            cutText("сегодня я хочу, сегодня я хочу рассказать о свете."),
            "сегодня я хочу рассказать о свете.")
    }

    func testRepeatedChainKeepsLast() {
        XCTAssertEqual(cutText("мы пошли мы пошли мы пошли домой."), "мы пошли домой.")
    }

    func testRestartAcrossPhrases() {
        XCTAssertEqual(
            cutText("Всем привет, сегодня | Всем привет, сегодня расскажу про монтаж."),
            "Всем привет, сегодня расскажу про монтаж.")
    }

    func testDoesNotCutNormalSpeech() {
        let texts = [
            "ставим свет на камеру, а потом звук на камеру.",
            "очень важно понять, что важно для зрителя.",
            "ну и что дальше?",
            "первое, второе и третье.",
            "мы снимаем, а потом мы монтируем.",
        ]
        for text in texts {
            XCTAssertEqual(cutText(text), text, text)
        }
    }

    // MARK: Целые предложения

    func testDuplicateSentenceKeepsLast() {
        let text =
            "Это самая важная настройка камеры. | Это самая важная настройка камеры. | Дальше поговорим о звуке."
        XCTAssertEqual(cutText(text), "Это самая важная настройка камеры. Дальше поговорим о звуке.")
        let (words, phrases) = transcript(text)
        let matches = RepeatFinder.find(words: words, phrases: phrases)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].kind, .sentence)
        XCTAssertEqual(matches[0].phraseID, 1)
        XCTAssertEqual(matches[0].keptPhraseID, 2)
    }

    func testThreeTakesKeepOnlyLast() {
        let text =
            "Включаем авиарежим перед записью. | Включаем авиарежим перед записью видео. | Включаем авиарежим перед каждой записью видео. | Готово."
        XCTAssertEqual(cutText(text), "Включаем авиарежим перед каждой записью видео. Готово.")
    }

    func testSimilarButDifferentSentencesStay() {
        let text = "Свет ставим слева от камеры. | Звук пишем на петличку. | Свет и звук настроены, начинаем запись."
        XCTAssertEqual(cutText(text), text.replacingOccurrences(of: " |", with: ""))
    }

    func testFarRepeatIsKept() {
        var options = RepeatFinder.Options()
        options.maxPhraseDistance = 2
        let (_, phrases) = transcript(
            "Подписывайтесь на канал обязательно. | один. | два. | три. | Подписывайтесь на канал обязательно.")
        XCTAssertTrue(RepeatFinder.sentenceRepeats(in: phrases, options: options).isEmpty)
    }

    func testSameWord() {
        XCTAssertTrue(RepeatFinder.same("погово", "поговорим"))
        XCTAssertTrue(RepeatFinder.same("монтаже", "монтажа"))
        XCTAssertFalse(RepeatFinder.same("на", "надо"))
        XCTAssertFalse(RepeatFinder.same("свет", "звук"))
    }
}
