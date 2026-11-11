import Foundation

/// Превращает паузы и решения по фразам в итоговый список резов.
public enum CutPlanner {

    public struct Options: Sendable, Equatable {
        /// Паузы короче этого значения не вырезаются.
        public var minPause: Double
        /// Отступ, который остаётся вокруг речи.
        public var padding: Double
        /// Оставшиеся куски короче этого значения выкидываются целиком.
        public var minKeep: Double
        /// Резы короче этого значения не имеют смысла (меньше пары кадров).
        public var minCut: Double

        public init(
            minPause: Double = 0.5, padding: Double = 0.12, minKeep: Double = 0.15,
            minCut: Double = 0.04
        ) {
            self.minPause = minPause
            self.padding = padding
            self.minKeep = minKeep
            self.minCut = minCut
        }
    }

    // MARK: - Интервалы

    /// Сортирует и объединяет пересекающиеся и соприкасающиеся интервалы.
    public static func merge(_ ranges: [TimeRange], tolerance: Double = 0) -> [TimeRange] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [TimeRange] = []
        for range in sorted {
            if let last = result.last, range.start <= last.end + tolerance {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Дополнение набора интервалов до [0, duration).
    public static func complement(of ranges: [TimeRange], duration: Double) -> [TimeRange] {
        var result: [TimeRange] = []
        var cursor = 0.0
        for range in merge(ranges) {
            let start = min(max(range.start, 0), duration)
            let end = min(max(range.end, 0), duration)
            if start > cursor { result.append(TimeRange(start: cursor, end: start)) }
            cursor = max(cursor, end)
        }
        if cursor < duration { result.append(TimeRange(start: cursor, end: duration)) }
        return result
    }

    // MARK: - Паузы

    /// Резы по тишине: промежутки между интервалами речи, не короче `minPause`,
    /// с отступом `padding` с каждой стороны, где рядом есть речь.
    public static func pauseCuts(speech: [TimeRange], duration: Double, options: Options) -> [TimeRange] {
        let speech = merge(speech)
        guard !speech.isEmpty else { return [] }
        var cuts: [TimeRange] = []
        for gap in complement(of: speech, duration: duration) where gap.duration >= options.minPause {
            let start = gap.start <= 0 ? 0 : gap.start + options.padding
            let end = gap.end >= duration ? duration : gap.end - options.padding
            if end - start >= options.minCut {
                cuts.append(TimeRange(start: start, end: end))
            }
        }
        return cuts
    }

    // MARK: - Слова и фразы

    /// Интервал, который нужно вырезать, чтобы убрать слова `range`.
    ///
    /// Вырезается сами слова и пауза после них, а «вдох» перед следующим словом остаётся.
    /// Так подряд идущие вырезанные куски склеиваются без дыр, а ритм речи на стыке сохраняется.
    public static func cutRange(
        forWords range: Range<Int>, in words: [Word], duration: Double, padding: Double
    ) -> TimeRange? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= words.count else { return nil }

        func lead(_ index: Int) -> Double {
            guard index > 0 else { return min(padding, max(0, words[index].start)) }
            let gap = max(0, words[index].start - words[index - 1].end)
            return min(padding, gap / 2)
        }

        let start = max(0, words[range.lowerBound].start - lead(range.lowerBound))
        let end: Double
        if range.upperBound < words.count {
            end = words[range.upperBound].start - lead(range.upperBound)
        } else {
            end = min(duration, words[range.upperBound - 1].end + padding)
        }
        guard end > start else { return nil }
        return TimeRange(start: start, end: end)
    }

    /// Резы по решениям детектора дублей.
    public static func retakeCuts(
        removals: [Removal], phrases: [Phrase], words: [Word], duration: Double, options: Options
    ) -> [Cut] {
        let byID = Dictionary(phrases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        var cuts: [Cut] = []
        for removal in removals where seen.insert(removal.id).inserted {
            guard let phrase = byID[removal.id],
                let range = cutRange(
                    forWords: phrase.wordRange, in: words, duration: duration, padding: options.padding)
            else { continue }
            cuts.append(
                Cut(
                    start: range.start, end: range.end, kind: removal.reason.cutKind,
                    phraseID: phrase.id))
        }
        return cuts.sorted { $0.start < $1.start }
    }

    // MARK: - Итог

    /// Итоговые резы: объединение включённых резов без огрызков.
    ///
    /// - Оставшиеся куски короче `minKeep` присоединяются к соседним резам.
    /// - Резы короче `minCut` отбрасываются.
    public static func finalCuts(_ ranges: [TimeRange], duration: Double, options: Options) -> [TimeRange] {
        guard duration > 0 else { return [] }
        let clamped = ranges.map {
            TimeRange(start: min(max($0.start, 0), duration), end: min(max($0.end, 0), duration))
        }
        var cuts = merge(clamped).filter { $0.duration >= options.minCut }

        // Убираем короткие оставшиеся куски, пока они есть: слияние может породить новые.
        while true {
            let keeps = complement(of: cuts, duration: duration)
            let slivers = keeps.filter { $0.duration < options.minKeep - 1e-6 }
            // Единственный оставшийся кусок не трогаем, иначе вырежется всё видео.
            if slivers.isEmpty || keeps.count == 1 { break }
            let merged = merge(cuts + slivers)
            if merged == cuts { break }
            cuts = merged
        }
        return cuts
    }

    public static func finalCuts(_ cuts: [Cut], duration: Double, options: Options) -> [TimeRange] {
        finalCuts(cuts.filter(\.enabled).map(\.range), duration: duration, options: options)
    }

    /// Интервалы исходника, которые попадут в готовый ролик.
    public static func keeps(cuts: [TimeRange], duration: Double) -> [TimeRange] {
        complement(of: cuts, duration: duration)
    }

    // MARK: - Привязка к кадрам

    /// Округляет границы оставляемых кусков до границ кадров и убирает пустые.
    public static func snapToFrames(_ keeps: [TimeRange], fps: Double, duration: Double) -> [TimeRange] {
        guard fps > 0 else { return keeps }
        let lastFrame = (duration * fps).rounded(.down)
        var result: [TimeRange] = []
        for keep in keeps {
            let startFrame = min(max((keep.start * fps).rounded(), 0), lastFrame)
            let endFrame = keep.end >= duration ? (duration * fps).rounded(.up) : (keep.end * fps).rounded()
            guard endFrame > startFrame else { continue }
            let start = startFrame / fps
            let end = min(endFrame / fps, duration)
            if let last = result.last, start <= last.end {
                result[result.count - 1].end = max(last.end, end)
            } else if end > start {
                result.append(TimeRange(start: start, end: end))
            }
        }
        return result
    }
}

// MARK: - Отображение времени исходник ↔ готовый ролик

public struct TimeMap: Sendable {
    public let keeps: [TimeRange]
    private let offsets: [Double]

    public init(keeps: [TimeRange]) {
        self.keeps = keeps
        var offsets: [Double] = []
        var total = 0.0
        for keep in keeps {
            offsets.append(total)
            total += keep.duration
        }
        self.offsets = offsets
        self.outputDuration = total
    }

    public let outputDuration: Double

    /// Время в готовом ролике для момента исходника. Вырезанные моменты прилипают к ближайшей склейке после них.
    public func outputTime(forSource time: Double) -> Double {
        for (index, keep) in keeps.enumerated() {
            if time < keep.start { return offsets[index] }
            if time < keep.end { return offsets[index] + (time - keep.start) }
        }
        return outputDuration
    }

    public func sourceTime(forOutput time: Double) -> Double {
        guard let last = keeps.last else { return 0 }
        for (index, keep) in keeps.enumerated() where time < offsets[index] + keep.duration {
            return keep.start + max(0, time - offsets[index])
        }
        return last.end
    }
}
