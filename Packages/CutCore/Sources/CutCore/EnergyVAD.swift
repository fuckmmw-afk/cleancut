import Foundation

/// Запасной детектор речи по RMS-порогу. Используется, если Silero VAD недоступен.
public enum EnergyVAD {

    public struct Options: Sendable {
        public var frameDuration: Double
        /// Насколько громче шумового фона должна быть речь, дБ.
        public var marginDB: Double
        public var minSpeech: Double
        /// Тишина короче этого значения внутри речи игнорируется.
        public var minSilence: Double

        public init(
            frameDuration: Double = 0.02, marginDB: Double = 12, minSpeech: Double = 0.12,
            minSilence: Double = 0.2
        ) {
            self.frameDuration = frameDuration
            self.marginDB = marginDB
            self.minSpeech = minSpeech
            self.minSilence = minSilence
        }
    }

    /// RMS по кадрам в дБFS.
    public static func frameLevels(_ samples: UnsafeBufferPointer<Float>, frameLength: Int) -> [Float] {
        guard frameLength > 0, samples.count >= frameLength else { return [] }
        let frames = samples.count / frameLength
        var levels = [Float](repeating: -120, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * frameLength
            for offset in 0..<frameLength {
                let value = samples[base + offset]
                sum += value * value
            }
            let rms = (sum / Float(frameLength)).squareRoot()
            levels[frame] = rms > 1e-6 ? 20 * log10(rms) : -120
        }
        return levels
    }

    public static func speechRanges(
        samples: [Float], sampleRate: Double, options: Options = Options()
    ) -> [TimeRange] {
        let frameLength = max(1, Int(sampleRate * options.frameDuration))
        let levels = samples.withUnsafeBufferPointer { frameLevels($0, frameLength: frameLength) }
        return speechRanges(levels: levels, frameDuration: Double(frameLength) / sampleRate, options: options)
    }

    public static func speechRanges(levels: [Float], frameDuration: Double, options: Options) -> [TimeRange] {
        guard !levels.isEmpty else { return [] }
        // Шумовой фон: 15-й перцентиль уровней. Порог не ниже -55 дБ, чтобы цифровая тишина не мешала.
        let sorted = levels.sorted()
        let noise = sorted[min(sorted.count - 1, sorted.count * 15 / 100)]
        let loud = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        var threshold = max(noise + Float(options.marginDB), -55)
        // Если запись очень ровная, порог не должен оказаться выше самой речи.
        threshold = min(threshold, loud - 6)

        var ranges: [TimeRange] = []
        var runStart: Int?
        for (index, level) in levels.enumerated() {
            if level >= threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                ranges.append(TimeRange(start: Double(start) * frameDuration, end: Double(index) * frameDuration))
                runStart = nil
            }
        }
        if let start = runStart {
            ranges.append(
                TimeRange(start: Double(start) * frameDuration, end: Double(levels.count) * frameDuration))
        }

        let joined = CutPlanner.merge(ranges, tolerance: options.minSilence)
        return joined.filter { $0.duration >= options.minSpeech }
    }
}
