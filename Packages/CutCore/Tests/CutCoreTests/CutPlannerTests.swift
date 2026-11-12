import XCTest

@testable import CutCore

final class CutPlannerTests: XCTestCase {
    let options = CutPlanner.Options(minPause: 0.5, padding: 0.12, minKeep: 0.15, minCut: 0.04)

    func r(_ start: Double, _ end: Double) -> TimeRange { TimeRange(start: start, end: end) }

    func assertRanges(
        _ actual: [TimeRange], _ expected: [TimeRange], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.start, e.start, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(a.end, e.end, accuracy: 1e-9, file: file, line: line)
        }
    }

    // MARK: Слияние

    func testMergeOverlappingAndTouching() {
        let merged = CutPlanner.merge([r(5, 6), r(1, 2), r(1.5, 3), r(3, 4), r(7, 7)])
        assertRanges(merged, [r(1, 4), r(5, 6)])
    }

    func testMergeNested() {
        assertRanges(CutPlanner.merge([r(0, 10), r(2, 3), r(9, 12)]), [r(0, 12)])
    }

    func testMergeWithTolerance() {
        assertRanges(CutPlanner.merge([r(0, 1), r(1.1, 2), r(3, 4)], tolerance: 0.2), [r(0, 2), r(3, 4)])
    }

    func testComplement() {
        assertRanges(CutPlanner.complement(of: [r(1, 2), r(4, 5)], duration: 6), [r(0, 1), r(2, 4), r(5, 6)])
        assertRanges(CutPlanner.complement(of: [r(-1, 2), r(5, 9)], duration: 6), [r(2, 5)])
        assertRanges(CutPlanner.complement(of: [], duration: 3), [r(0, 3)])
    }

    // MARK: Паузы и отступы

    func testPauseCutsApplyPaddingAndMinPause() {
        // Паузы: 1.0–1.3 (короткая), 2.0–3.0 (длинная).
        let speech = [r(0, 1.0), r(1.3, 2.0), r(3.0, 4.0)]
        let cuts = CutPlanner.pauseCuts(speech: speech, duration: 4.0, options: options)
        assertRanges(cuts, [r(2.12, 2.88)])
    }

    func testTailPaddingIsSeparate() {
        let asymmetric = CutPlanner.Options(minPause: 0.5, padding: 0.12, tailPadding: 0.05)
        let cuts = CutPlanner.pauseCuts(speech: [r(0, 1.0), r(2.0, 3.0)], duration: 3, options: asymmetric)
        assertRanges(cuts, [r(1.05, 1.88)])
    }

    func testPauseCutsAtEdgesHaveNoOuterPadding() {
        let speech = [r(1.0, 2.0)]
        let cuts = CutPlanner.pauseCuts(speech: speech, duration: 4.0, options: options)
        assertRanges(cuts, [r(0, 0.88), r(2.12, 4.0)])
    }

    func testPauseExactlyMinPauseIsCut() {
        let cuts = CutPlanner.pauseCuts(speech: [r(0, 1), r(1.5, 2)], duration: 2, options: options)
        assertRanges(cuts, [r(1.12, 1.38)])
    }

    func testNoSpeechMeansNoCuts() {
        XCTAssertTrue(CutPlanner.pauseCuts(speech: [], duration: 10, options: options).isEmpty)
    }

    func testPaddingLargerThanPauseGivesNoCut() {
        var wide = options
        wide.padding = 0.3
        wide.tailPadding = 0.3
        XCTAssertTrue(CutPlanner.pauseCuts(speech: [r(0, 1), r(1.55, 2)], duration: 2, options: wide).isEmpty)
    }

    // MARK: Слова

    func testCutRangeKeepsLeadOfNextWord() {
        let words = [
            Word(text: "раз", start: 0.0, end: 0.4),
            Word(text: "два", start: 0.5, end: 0.9),
            Word(text: "три", start: 1.5, end: 1.9),
            Word(text: "четыре", start: 2.0, end: 2.5),
        ]
        // Вырезаем «два»: начало с половиной короткого зазора, конец за отступ до «три».
        let range = CutPlanner.cutRange(forWords: 1..<2, in: words, duration: 3, padding: 0.12)
        XCTAssertEqual(range!.start, 0.45, accuracy: 1e-9)
        XCTAssertEqual(range!.end, 1.38, accuracy: 1e-9)

        // Последнее слово: отступ после него, но не дальше конца файла.
        let tail = CutPlanner.cutRange(forWords: 3..<4, in: words, duration: 2.55, padding: 0.12)
        XCTAssertEqual(tail!.start, 1.95, accuracy: 1e-9)
        XCTAssertEqual(tail!.end, 2.55, accuracy: 1e-9)

        XCTAssertNil(CutPlanner.cutRange(forWords: 2..<2, in: words, duration: 3, padding: 0.12))
        XCTAssertNil(CutPlanner.cutRange(forWords: 3..<5, in: words, duration: 3, padding: 0.12))
    }

    func testAdjacentPhraseCutsMergeWithoutGap() {
        let words = [
            Word(text: "а", start: 0.0, end: 0.4), Word(text: "б", start: 1.0, end: 1.4),
            Word(text: "в", start: 2.0, end: 2.4), Word(text: "г", start: 3.0, end: 3.4),
        ]
        let phrases = PhraseSegmenter.phrases(from: words)
        XCTAssertEqual(phrases.count, 4)
        let cuts = CutPlanner.retakeCuts(
            removals: [Removal(id: 2, reason: .retake), Removal(id: 3, reason: .falseStart)],
            phrases: phrases, words: words, duration: 4, options: options)
        XCTAssertEqual(cuts.map(\.kind), [.retake, .falseStart])
        XCTAssertEqual(cuts[0].end, cuts[1].start, accuracy: 1e-9)
        let final = CutPlanner.finalCuts(cuts, duration: 4, options: options)
        assertRanges(final, [r(0.88, 2.88)])
    }

    func testRetakeCutsIgnoreUnknownAndDuplicateIDs() {
        let words = [Word(text: "а.", start: 0, end: 0.4), Word(text: "б.", start: 1, end: 1.4)]
        let phrases = PhraseSegmenter.phrases(from: words)
        let cuts = CutPlanner.retakeCuts(
            removals: [
                Removal(id: 1, reason: .retake), Removal(id: 1, reason: .garbage),
                Removal(id: 99, reason: .retake),
            ],
            phrases: phrases, words: words, duration: 2, options: options)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].phraseID, 1)
    }

    // MARK: Огрызки

    func testSliverBetweenCutsIsRemoved() {
        // Между резами остаётся 0.1 с: меньше minKeep, должно уйти.
        let final = CutPlanner.finalCuts([r(1, 2), r(2.1, 3)], duration: 5, options: options)
        assertRanges(final, [r(1, 3)])
    }

    func testSliverAtEdgesIsRemoved() {
        let final = CutPlanner.finalCuts([r(0.1, 2), r(3, 4.95)], duration: 5, options: options)
        assertRanges(final, [r(0, 2), r(3, 5)])
    }

    func testKeepExactlyMinKeepSurvives() {
        let final = CutPlanner.finalCuts([r(1, 2), r(2.15, 3)], duration: 5, options: options)
        assertRanges(final, [r(1, 2), r(2.15, 3)])
    }

    func testTinyCutIsDropped() {
        let final = CutPlanner.finalCuts([r(1, 1.02), r(3, 4)], duration: 5, options: options)
        assertRanges(final, [r(3, 4)])
    }

    func testCutsAreClampedToDuration() {
        let final = CutPlanner.finalCuts([r(-1, 1), r(4, 9)], duration: 5, options: options)
        assertRanges(final, [r(0, 1), r(4, 5)])
    }

    func testNeverCutsEverything() {
        let final = CutPlanner.finalCuts([r(0, 4.9)], duration: 5, options: options)
        assertRanges(final, [r(0, 4.9)])
    }

    func testDisabledCutsAreIgnored() {
        let cuts = [
            Cut(start: 1, end: 2, kind: .pause), Cut(start: 3, end: 4, kind: .retake, enabled: false),
        ]
        assertRanges(CutPlanner.finalCuts(cuts, duration: 5, options: options), [r(1, 2)])
    }

    func testSilenceAndRetakesCombine() {
        let pause = CutPlanner.pauseCuts(speech: [r(0, 2), r(3, 5), r(5.2, 8)], duration: 8, options: options)
        let all = pause + [r(2.8, 5.1)]
        assertRanges(CutPlanner.finalCuts(all, duration: 8, options: options), [r(2.12, 5.1)])
    }

    // MARK: Кадры и карта времени

    func testSnapToFrames() {
        let keeps = [r(0, 1.01), r(2.02, 3.0)]
        let snapped = CutPlanner.snapToFrames(keeps, fps: 30, duration: 3.0)
        assertRanges(snapped, [r(0, 30.0 / 30), r(61.0 / 30, 3.0)])
        for keep in snapped {
            let frames = keep.start * 30
            XCTAssertEqual(frames, frames.rounded(), accuracy: 1e-6)
        }
    }

    func testSnapDropsEmptyAndJoinsTouching() {
        let snapped = CutPlanner.snapToFrames([r(0, 1.0), r(1.004, 2.0), r(2.5, 2.505)], fps: 30, duration: 3)
        assertRanges(snapped, [r(0, 2.0)])
    }

    func testTimeMapRoundTrip() {
        let map = TimeMap(keeps: [r(0, 1), r(2, 4)])
        XCTAssertEqual(map.outputDuration, 3, accuracy: 1e-9)
        XCTAssertEqual(map.outputTime(forSource: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(map.outputTime(forSource: 1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(map.outputTime(forSource: 3.0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(map.outputTime(forSource: 9.0), 3.0, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(forOutput: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(forOutput: 1.0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(forOutput: 2.5), 3.5, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(forOutput: 99), 4.0, accuracy: 1e-9)
    }
}
