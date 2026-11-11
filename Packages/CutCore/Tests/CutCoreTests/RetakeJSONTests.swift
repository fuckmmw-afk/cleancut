import XCTest

@testable import CutCore

final class RetakeJSONTests: XCTestCase {
    let ids: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8]

    func testCleanJSON() throws {
        let result = try RetakeJSON.parse(
            #"{"remove":[{"id":3,"reason":"retake"},{"id":1,"reason":"false_start"},{"id":7,"reason":"garbage"}]}"#,
            allowedIDs: ids)
        XCTAssertEqual(
            result,
            [
                Removal(id: 1, reason: .falseStart), Removal(id: 3, reason: .retake),
                Removal(id: 7, reason: .garbage),
            ])
    }

    func testEmptyRemove() throws {
        XCTAssertEqual(try RetakeJSON.parse(#"{"remove":[]}"#, allowedIDs: ids), [])
    }

    func testCodeFenceAndChatter() throws {
        let text = """
            Вот результат:
            ```json
            {
              "remove": [ {"id": 2, "reason": "retake"} ]
            }
            ```
            Готово!
            """
        XCTAssertEqual(try RetakeJSON.parse(text, allowedIDs: ids), [Removal(id: 2, reason: .retake)])
    }

    func testThinkBlockIsIgnored() throws {
        let text = #"<think>может {"remove":[{"id":5,"reason":"retake"}]} ?</think>{"remove":[{"id":4,"reason":"garbage"}]}"#
        XCTAssertEqual(try RetakeJSON.parse(text, allowedIDs: ids), [Removal(id: 4, reason: .garbage)])
    }

    func testUnclosedThinkBlockFails() {
        XCTAssertThrowsError(try RetakeJSON.parse(#"<think>{"remove":[]}"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .noJSONObject)
        }
    }

    func testBracesInsideStrings() throws {
        let text = #"{"note":"скобка } внутри \" строки","remove":[{"id":"6","reason":"False-Start"}]}"#
        XCTAssertEqual(try RetakeJSON.parse(text, allowedIDs: ids), [Removal(id: 6, reason: .falseStart)])
    }

    func testDuplicatesAreCollapsed() throws {
        let text = #"{"remove":[{"id":2,"reason":"retake"},{"id":2,"reason":"garbage"}]}"#
        XCTAssertEqual(try RetakeJSON.parse(text, allowedIDs: ids), [Removal(id: 2, reason: .retake)])
    }

    func testNoJSON() {
        XCTAssertThrowsError(try RetakeJSON.parse("Ничего вырезать не нужно.", allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .noJSONObject)
        }
    }

    func testTruncatedJSON() {
        XCTAssertThrowsError(try RetakeJSON.parse(#"{"remove":[{"id":2,"reason":"ret"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .noJSONObject)
        }
    }

    func testBrokenJSON() {
        XCTAssertThrowsError(try RetakeJSON.parse(#"{"remove":[{"id":2 "reason":"retake"}]}"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .invalidJSON)
        }
    }

    func testMissingRemove() {
        XCTAssertThrowsError(try RetakeJSON.parse(#"{"cut":[1,2]}"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .missingRemoveArray)
        }
        XCTAssertThrowsError(try RetakeJSON.parse(#"{"remove":"none"}"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .missingRemoveArray)
        }
    }

    func testInvalidItems() {
        let bad = [
            #"{"remove":[3]}"#,
            #"{"remove":[{"id":3}]}"#,
            #"{"remove":[{"id":3,"reason":"boring"}]}"#,
            #"{"remove":[{"id":2.5,"reason":"retake"}]}"#,
            #"{"remove":[{"id":true,"reason":"retake"}]}"#,
            #"{"remove":[{"reason":"retake"}]}"#,
        ]
        for text in bad {
            XCTAssertThrowsError(try RetakeJSON.parse(text, allowedIDs: ids), text) {
                XCTAssertEqual($0 as? RetakeJSON.ParseError, .invalidItem, text)
            }
        }
    }

    func testUnknownID() {
        XCTAssertThrowsError(try RetakeJSON.parse(#"{"remove":[{"id":42,"reason":"retake"}]}"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .unknownID(42))
        }
    }

    func testTooManyRemovals() {
        let items = (1...7).map { #"{"id":\#($0),"reason":"retake"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try RetakeJSON.parse(#"{"remove":[\#(items)]}"#, allowedIDs: ids)) {
            XCTAssertEqual($0 as? RetakeJSON.ParseError, .tooManyRemovals(7, of: 8))
        }
    }

    // MARK: Чанки

    func makePhrases(_ count: Int) -> [Phrase] {
        (1...count).map {
            Phrase(id: $0, start: Double($0), end: Double($0) + 0.5, text: "фраза \($0)", firstWord: $0 - 1, wordCount: 1)
        }
    }

    func testChunksCoverEverythingWithOverlap() {
        let phrases = makePhrases(100)
        let chunks = RetakePrompt.chunks(phrases, size: 40, overlap: 8)
        XCTAssertEqual(chunks.map { $0.phrases.first!.id }, [1, 33, 65])
        XCTAssertEqual(chunks.map { $0.phrases.last!.id }, [40, 72, 100])
        XCTAssertTrue(chunks[0].overlapIDs.isEmpty)
        XCTAssertEqual(chunks[1].overlapIDs, Set(33...40))
        XCTAssertEqual(Set(chunks.flatMap { $0.phrases.map(\.id) }), Set(1...100))
    }

    func testSingleChunk() {
        let chunks = RetakePrompt.chunks(makePhrases(5), size: 40, overlap: 8)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(RetakePrompt.chunks([], size: 40, overlap: 8).isEmpty)
    }

    func testMergeDeduplicatesAndGuardsOverlap() {
        let chunks = RetakePrompt.chunks(makePhrases(60), size: 40, overlap: 8)
        let merged = RetakePrompt.mergeResults([
            (chunks[0], [Removal(id: 5, reason: .retake), Removal(id: 35, reason: .garbage)]),
            (
                chunks[1],
                [
                    Removal(id: 34, reason: .falseStart),  // перекрытие, первый чанк не согласен
                    Removal(id: 35, reason: .garbage),  // перекрытие, первый согласен
                    Removal(id: 36, reason: .retake),  // перекрытие, дубль принимаем
                    Removal(id: 50, reason: .falseStart),
                ]
            ),
        ])
        XCTAssertEqual(
            merged,
            [
                Removal(id: 5, reason: .retake), Removal(id: 35, reason: .garbage),
                Removal(id: 36, reason: .retake), Removal(id: 50, reason: .falseStart),
            ])
    }

    func testPromptListsPhrases() {
        let chunk = RetakePrompt.chunks(makePhrases(2), size: 40, overlap: 8)[0]
        let prompt = RetakePrompt.user(for: chunk)
        XCTAssertTrue(prompt.contains("1 [00:01.0–00:01.5] фраза 1"))
        XCTAssertEqual(RetakePrompt.timecode(83.44), "01:23.4")
    }
}
