import Foundation

/// Собирает интервалы речи из вероятностей Silero VAD и уточняет границы по энергии сигнала.
///
/// Core ML-версия Silero отдаёт одну вероятность на окно 256 мс, для монтажа это грубо.
/// Поэтому решение «речь / не речь» принимает Silero, а точную границу внутри окна ищем по RMS (шаг 20 мс).
public enum SpeechSegmenter {

    public struct Options: Sendable {
        public var onThreshold: Float
        public var offThreshold: Float
        public var minSpeech: Double
        /// Тишина короче этого значения внутри речи игнорируется.
        public var joinGap: Double
        public var energyMarginDB: Double
        /// Тишина по громкости не короче этого значения разрывает интервал Silero.
        /// Silero отпускает речь с опозданием и сливает соседние фразы через короткую паузу.
        public var splitGap: Double
        /// Насколько тише самой фразы может быть её край. Всё, что тише, — фон, дыхание, шорох.
        /// Нужен там, где фон в паузах громче общего порога: шумная комната, перелистывание страниц.
        public var localDropDB: Double

        public init(
            onThreshold: Float = 0.6, offThreshold: Float = 0.4, minSpeech: Double = 0.1,
            joinGap: Double = 0.1, energyMarginDB: Double = 10, splitGap: Double = 0.3, localDropDB: Double = 30
        ) {
            self.localDropDB = localDropDB
            self.onThreshold = onThreshold
            self.offThreshold = offThreshold
            self.minSpeech = minSpeech
            self.joinGap = joinGap
            self.energyMarginDB = energyMarginDB
            self.splitGap = splitGap
        }
    }

    /// Грубые интервалы по вероятностям с гистерезисом, на сетке `hop`.
    public static func coarseRanges(probabilities: [Float], hop: Double, options: Options = Options()) -> [TimeRange] {
        var ranges: [TimeRange] = []
        var start: Int?
        for (index, probability) in probabilities.enumerated() {
            if start == nil, probability >= options.onThreshold {
                start = index
            } else if let begin = start, probability < options.offThreshold {
                ranges.append(TimeRange(start: Double(begin) * hop, end: Double(index) * hop))
                start = nil
            }
        }
        if let begin = start {
            ranges.append(TimeRange(start: Double(begin) * hop, end: Double(probabilities.count) * hop))
        }
        return ranges
    }

    /// - Parameters:
    ///   - probabilities: вероятность речи на каждое окно длиной `hop` секунд.
    ///   - levels: RMS в дБFS по кадрам длиной `frameDuration` секунд.
    public static func speechRanges(
        probabilities: [Float], hop: Double, levels: [Float], frameDuration: Double, duration: Double,
        options: Options = Options()
    ) -> [TimeRange] {
        let coarse = coarseRanges(probabilities: probabilities, hop: hop, options: options)
        guard !coarse.isEmpty, !levels.isEmpty, frameDuration > 0 else {
            return coarse.map { TimeRange(start: $0.start, end: min($0.end, duration)) }
        }

        let sorted = levels.sorted()
        let noise = sorted[min(sorted.count - 1, sorted.count * 15 / 100)]
        let loud = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let threshold = min(max(noise + Float(options.energyMarginDB), -55), loud - 6)

        func frame(_ time: Double) -> Int { min(max(Int((time / frameDuration).rounded()), 0), levels.count) }

        var refined: [TimeRange] = []
        for range in coarse {
            var start = range.start
            var end = min(range.end, duration)

            // Громкость самой фразы: края ищем относительно неё, а не только относительно всего ролика.
            let localLow = frame(range.start - hop)
            let localHigh = frame(end + hop)
            var local = threshold
            if localLow < localHigh {
                let sortedLocal = levels[localLow..<localHigh].sorted()
                let peak = sortedLocal[min(sortedLocal.count - 1, sortedLocal.count * 90 / 100)]
                local = Float(Double(peak) - options.localDropDB)
            }
            let startThreshold = max(threshold, local)

            // Начало: первый громкий кадр в пределах одного окна в обе стороны от грубой границы.
            let startLow = localLow
            let startHigh = min(frame(range.start + hop), frame(end))
            if startLow < startHigh, let first = (startLow..<startHigh).first(where: { levels[$0] >= startThreshold }) {
                start = Double(first) * frameDuration
            }

            // Конец: последний громкий кадр до грубой границы плюс окно. Silero держит «речь»
            // на одно-три окна после последнего слова, поэтому ищем назад до самого начала интервала,
            // а не только в соседнем окне. Порог чуть выше, чтобы выдох и эхо не считались речью.
            let endThreshold = max(min(threshold + 4, loud - 6), local + 3)
            let endLow = frame(start)
            let endHigh = frame(end + hop)
            if endLow < endHigh, let last = (endLow..<endHigh).last(where: { levels[$0] >= endThreshold }) {
                end = Double(last + 1) * frameDuration
            }

            guard end > start else { continue }
            refined += split(
                TimeRange(start: max(0, start), end: min(end, duration)), levels: levels,
                frameDuration: frameDuration, threshold: startThreshold, minGap: options.splitGap)
        }

        return CutPlanner.merge(refined, tolerance: options.joinGap).filter { $0.duration >= options.minSpeech }
    }

    /// Разрезает интервал по тихим участкам не короче `minGap`.
    static func split(
        _ range: TimeRange, levels: [Float], frameDuration: Double, threshold: Float, minGap: Double
    ) -> [TimeRange] {
        guard minGap > 0 else { return [range] }
        let first = max(0, Int((range.start / frameDuration).rounded()))
        let last = min(levels.count, Int((range.end / frameDuration).rounded()))
        let minFrames = Int((minGap / frameDuration).rounded(.up))
        guard last - first > minFrames else { return [range] }

        var result: [TimeRange] = []
        var cursor = range.start
        var quietStart: Int?
        for index in first..<last {
            if levels[index] < threshold {
                if quietStart == nil { quietStart = index }
            } else if let quiet = quietStart {
                if index - quiet >= minFrames {
                    let gapStart = Double(quiet) * frameDuration
                    if gapStart > cursor { result.append(TimeRange(start: cursor, end: gapStart)) }
                    cursor = Double(index) * frameDuration
                }
                quietStart = nil
            }
        }
        if range.end > cursor { result.append(TimeRange(start: cursor, end: range.end)) }
        return result
    }
}
