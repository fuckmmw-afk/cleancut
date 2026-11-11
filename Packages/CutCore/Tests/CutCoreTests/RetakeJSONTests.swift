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

    func testKeptField() throws {
        let text = #"{"remove":[{"id":2,"kept":5,"reason":"retake"},{"id":3,"kept":0,"reason":"garbage"}]}"#
        XCTAssertEqual(
            try RetakeJSON.parse(text, allowedIDs: ids),
            [Removal(id: 2, reason: .retake, kept: 5), Removal(id: 3, reason: .garbage)])
    }

    // MARK: Окна

    func makePhrases(_ count: Int) -> [Phrase] {
        (1...count).map {
            Phrase(id: $0, start: Double($0), end: Double($0) + 0.5, text: "фраза \($0)", firstWord: $0 - 1, wordCount: 1)
        }
    }

    func testShortTranscriptIsOneWindow() {
        let windows = RetakePrompt.windows(makePhrases(80))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].targetIDs, Set(1...80))
        XCTAssertTrue(RetakePrompt.windows([]).isEmpty)
    }

    func testWindowsHaveContextAndDisjointTargets() {
        let windows = RetakePrompt.windows(makePhrases(130), target: 50, before: 30, after: 15, wholeLimit: 90)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map { $0.targets.first!.id }, [1, 51, 101])
        XCTAssertEqual(windows.map { $0.targets.last!.id }, [50, 100, 130])
        XCTAssertEqual(windows.map { $0.phrases.first!.id }, [1, 21, 71])
        XCTAssertEqual(windows.map { $0.phrases.last!.id }, [65, 115, 130])
        var all = Set<Int>()
        for window in windows {
            XCTAssertTrue(all.isDisjoint(with: window.targetIDs))
            all.formUnion(window.targetIDs)
        }
        XCTAssertEqual(all, Set(1...130))
    }

    func testMergeKeepsOnlyTargets() {
        let windows = RetakePrompt.windows(makePhrases(130), target: 50, before: 30, after: 15, wholeLimit: 90)
        let merged = RetakePrompt.mergeResults([
            (windows[0], [Removal(id: 5, reason: .retake, kept: 7), Removal(id: 60, reason: .garbage)]),
            (windows[1], [Removal(id: 40, reason: .retake, kept: 41), Removal(id: 60, reason: .garbage)]),
        ])
        XCTAssertEqual(merged, [Removal(id: 5, reason: .retake, kept: 7), Removal(id: 60, reason: .garbage)])
    }

    func testPromptAndSchema() throws {
        let window = RetakePrompt.windows(makePhrases(130), target: 50, before: 30, after: 15, wholeLimit: 90)[1]
        let prompt = RetakePrompt.user(for: window)
        XCTAssertTrue(prompt.contains("21 [00:21.0–00:21.5] фраза 21"))
        XCTAssertTrue(prompt.contains("от 51 до 100"))
        XCTAssertEqual(RetakePrompt.timecode(83.44), "01:23.4")

        let schema = RetakePrompt.jsonSchema(for: window)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let items = try XCTUnwrap(
            ((object["properties"] as? [String: Any])?["remove"] as? [String: Any])?["items"] as? [String: Any])
        let properties = try XCTUnwrap(items["properties"] as? [String: Any])
        let ids = try XCTUnwrap((properties["id"] as? [String: Any])?["enum"] as? [Int])
        let kept = try XCTUnwrap((properties["kept"] as? [String: Any])?["enum"] as? [Int])
        XCTAssertEqual(ids, Array(51...100))
        XCTAssertEqual(kept, [0] + Array(21...115))
    }
}
