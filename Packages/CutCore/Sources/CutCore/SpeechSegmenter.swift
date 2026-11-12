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

        public init(
            onThreshold: Float = 0.6, offThreshold: Float = 0.4, minSpeech: Double = 0.1,
            joinGap: Double = 0.1, energyMarginDB: Double = 10
        ) {
            self.onThreshold = onThreshold
            self.offThreshold = offThreshold
            self.minSpeech = minSpeech
            self.joinGap = joinGap
            self.energyMarginDB = energyMarginDB
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

            // Начало: первый громкий кадр в пределах одного окна в обе стороны от грубой границы.
            let startLow = frame(range.start - hop)
            let startHigh = min(frame(range.start + hop), frame(end))
            if startLow < startHigh, let first = (startLow..<startHigh).first(where: { levels[$0] >= threshold }) {
                start = Double(first) * frameDuration
            }

            // Конец: последний громкий кадр рядом с грубой границей. Порог чуть выше, чтобы выдох
            // и хвост эха после фразы не считались речью.
            let endThreshold = min(threshold + 4, loud - 6)
            let endLow = max(frame(end - hop), frame(start))
            let endHigh = frame(end + hop)
            if endLow < endHigh, let last = (endLow..<endHigh).last(where: { levels[$0] >= endThreshold }) {
                end = Double(last + 1) * frameDuration
            }

            if end > start {
                refined.append(TimeRange(start: max(0, start), end: min(end, duration)))
            }
        }

        return CutPlanner.merge(refined, tolerance: options.joinGap).filter { $0.duration >= options.minSpeech }
    }
}
