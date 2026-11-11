@preconcurrency import AVFoundation
import CutCore
import Foundation
import Observation
import SwiftUI

extension CutKind {
    var label: String {
        switch self {
        case .pause: "пауза"
        case .retake: "дубль"
        case .falseStart: "фальстарт"
        case .garbage: "мусор"
        case .manual: "вручную"
        }
    }

    var color: Color {
        switch self {
        case .pause: .gray
        case .retake: .red
        case .falseStart: .orange
        case .garbage: .purple
        case .manual: .yellow
        }
    }
}

@MainActor
@Observable
final class ReviewModel {
    enum TapMode: String, CaseIterable, Identifiable {
        case cut, seek, select

        var id: String { rawValue }
        var title: String {
            switch self {
            case .cut: "Резать"
            case .seek: "Перемотка"
            case .select: "Выделение"
            }
        }
    }

    enum Item: Identifiable {
        case phrase(Phrase)
        case pause(Cut)

        var id: String {
            switch self {
            case .phrase(let phrase): "p\(phrase.id)"
            case .pause(let cut): "c\(cut.id.uuidString)"
            }
        }

        var start: Double {
            switch self {
            case .phrase(let phrase): phrase.start
            case .pause(let cut): cut.start
            }
        }
    }

    private(set) var project: Project
    private(set) var finalCuts: [TimeRange] = []
    /// Для каждого слова: nil, если оно остаётся, иначе причина, по которой вырезано.
    private(set) var wordKinds: [CutKind?] = []
    private(set) var items: [Item] = []
    private(set) var outputDuration: Double = 0
    private(set) var currentSourceTime: Double = 0
    private(set) var currentOutputTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var canUndo = false
    private(set) var selection: ClosedRange<Int>?
    var error: AppError?
    var tapMode: TapMode = .cut {
        didSet { if tapMode != .select { clearSelection() } }
    }

    let player = AVPlayer()

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var builder: CompositionBuilder?
    @ObservationIgnored private var timeMap = TimeMap(keeps: [])
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var history: [[Cut]] = []
    @ObservationIgnored private var selectionAnchor: Int?

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        outputDuration = project.outputDuration
        recompute()
    }

    // MARK: - Загрузка

    func load() async {
        guard builder == nil else { return }
        do {
            builder = try await CompositionBuilder.load(url: ProjectStore.sourceURL(for: project))
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
            rebuildPlayer()
            isReady = true
        } catch {
            self.error = AppError.wrap(error, title: "Видео не открылось")
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        builder = nil
        isReady = false
    }

    // MARK: - Состояние резов

    var cutCount: Int { finalCuts.count }

    /// Вырезана ли фраза целиком и по какой причине.
    func phraseKind(_ phrase: Phrase) -> CutKind? {
        let kinds = phrase.wordRange.map { wordKinds.indices.contains($0) ? wordKinds[$0] : nil }
        guard !kinds.isEmpty, kinds.allSatisfy({ $0 != nil }) else { return nil }
        return kinds.compactMap { $0 }.first { $0 != .pause } ?? .pause
    }

    func isCurrent(_ phrase: Phrase) -> Bool {
        currentSourceTime >= phrase.start && currentSourceTime < phrase.end
    }

    private func recompute() {
        finalCuts = project.finalCuts
        let reasons = project.cuts.filter { $0.enabled && $0.kind != .pause }
        wordKinds = project.words.map { word in
            let mid = word.mid
            if let cut = reasons.first(where: { $0.range.contains(mid) }) { return cut.kind }
            if finalCuts.contains(where: { $0.contains(mid) }) { return .pause }
            return nil
        }
        let pauses = project.cuts.filter { $0.kind == .pause }.map(Item.pause)
        items = (project.phrases.map(Item.phrase) + pauses).sorted { $0.start < $1.start }
    }

    private func commit() {
        project.cuts.sort { $0.start < $1.start }
        recompute()
        store.save(project)
        rebuildPlayer()
    }

    private func pushHistory() {
        history.append(project.cuts)
        if history.count > 100 { history.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        canUndo = !history.isEmpty
        project.cuts = previous
        commit()
    }

    // MARK: - Правки

    func tapPhrase(_ phrase: Phrase) {
        switch tapMode {
        case .seek:
            seek(toSource: phrase.start)
            play()
        case .cut:
            togglePhrase(phrase)
            // Перематываем чуть раньше, чтобы сразу услышать, как звучит место правки.
            seek(toOutput: max(0, timeMap.outputTime(forSource: phrase.start) - 1.0))
        case .select:
            break
        }
    }

    private func togglePhrase(_ phrase: Phrase) {
        pushHistory()
        let isCut = phrase.wordRange.contains { index in
            guard wordKinds.indices.contains(index), let kind = wordKinds[index] else { return false }
            return kind != .pause
        }
        if isCut {
            // Возвращаем фразу: выключаем все резы-причины, которые её задевают.
            let span = TimeRange(start: phrase.start, end: phrase.end)
            project.cuts.removeAll { $0.kind == .manual && $0.enabled && $0.range.overlaps(span) }
            for index in project.cuts.indices
            where project.cuts[index].enabled && project.cuts[index].kind != .pause
                && project.cuts[index].range.overlaps(span)
            {
                project.cuts[index].enabled = false
            }
        } else if let index = project.cuts.firstIndex(where: { $0.phraseID == phrase.id && !$0.enabled }) {
            project.cuts[index].enabled = true
        } else if let range = CutPlanner.cutRange(
            forWords: phrase.wordRange, in: project.words, duration: project.duration, padding: project.padding)
        {
            project.cuts.append(Cut(start: range.start, end: range.end, kind: .manual, phraseID: phrase.id))
        }
        commit()
    }

    func tapPause(_ cut: Cut) {
        guard let index = project.cuts.firstIndex(where: { $0.id == cut.id }) else { return }
        if tapMode == .seek {
            seek(toSource: cut.start)
            play()
            return
        }
        pushHistory()
        project.cuts[index].enabled.toggle()
        commit()
        seek(toOutput: max(0, timeMap.outputTime(forSource: cut.start) - 1.0))
    }

    func tapWord(_ index: Int) {
        guard project.words.indices.contains(index) else { return }
        if let anchor = selectionAnchor {
            selection = min(anchor, index)...max(anchor, index)
            selectionAnchor = nil
        } else {
            selectionAnchor = index
            selection = index...index
        }
    }

    func clearSelection() {
        selection = nil
        selectionAnchor = nil
    }

    var selectionText: String {
        guard let selection else { return "" }
        let count = selection.count
        let seconds = project.words[selection.upperBound].end - project.words[selection.lowerBound].start
        return "\(count) сл. · \(String(format: "%.1f", seconds)) с"
    }

    func cutSelection() {
        guard let selection,
            let range = CutPlanner.cutRange(
                forWords: selection.lowerBound..<(selection.upperBound + 1), in: project.words,
                duration: project.duration, padding: project.padding)
        else { return }
        pushHistory()
        project.cuts.append(Cut(start: range.start, end: range.end, kind: .manual))
        let start = range.start
        clearSelection()
        commit()
        seek(toOutput: max(0, timeMap.outputTime(forSource: start) - 1.0))
    }

    /// Возвращает выделенные слова: убирает ручные резы и выключает найденные автоматически.
    func restoreSelection() {
        guard let selection else { return }
        let span = TimeRange(
            start: project.words[selection.lowerBound].start, end: project.words[selection.upperBound].end)
        pushHistory()
        project.cuts.removeAll { $0.kind == .manual && $0.range.overlaps(span) }
        for index in project.cuts.indices where project.cuts[index].range.overlaps(span) {
            project.cuts[index].enabled = false
        }
        clearSelection()
        commit()
    }

    /// Пересчитывает паузы с новыми настройками. Дубли и ручные правки не трогает.
    func recomputePauses(minPause: Double, padding: Double) {
        pushHistory()
        project.minPause = minPause
        project.padding = padding
        project.cuts.removeAll { $0.kind == .pause }
        project.cuts += CutPlanner.pauseCuts(
            speech: project.speech, duration: project.duration, options: project.plannerOptions
        ).map { Cut(start: $0.start, end: $0.end, kind: .pause) }
        commit()
    }

    // MARK: - Плеер

    private func rebuildPlayer() {
        guard let builder else { return }
        do {
            let built = try builder.make(cuts: finalCuts)
            timeMap = TimeMap(keeps: built.keeps)
            outputDuration = timeMap.outputDuration
            let wasPlaying = isPlaying
            let source = currentSourceTime
            let asset = (built.composition.copy() as? AVAsset) ?? built.composition
            let item = AVPlayerItem(asset: asset)
            item.audioMix = built.audioMix
            player.replaceCurrentItem(with: item)
            seek(toSource: source)
            if wasPlaying { player.play() }
        } catch {
            self.error = AppError.wrap(error, title: "Не получилось собрать ролик")
        }
    }

    private func tick(_ outputTime: Double) {
        guard outputTime.isFinite else { return }
        currentOutputTime = outputTime
        currentSourceTime = timeMap.sourceTime(forOutput: outputTime)
        isPlaying = player.rate != 0
    }

    func seek(toSource time: Double) {
        seek(toOutput: timeMap.outputTime(forSource: time))
    }

    func seek(toOutput time: Double) {
        let clamped = min(max(0, time), max(0, outputDuration))
        currentOutputTime = clamped
        currentSourceTime = timeMap.sourceTime(forOutput: clamped)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() {
        if currentOutputTime >= outputDuration - 0.05 { seek(toOutput: 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        if player.rate != 0 { pause() } else { play() }
    }
}
