import CutCore
import FluidAudio
import Foundation

/// Ищет интервалы речи. Основной путь: Silero VAD (Core ML, через FluidAudio) с уточнением границ по RMS.
/// Запасной путь: только RMS-порог.
enum SpeechDetector {

    struct Result: Sendable {
        var speech: [TimeRange]
        var usedSilero: Bool
        /// Замечание для пользователя, если пришлось откатиться на запасной вариант.
        var note: String?
    }

    static func detect(
        samples: [Float], useSilero: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        let rate = Double(AudioExtractor.sampleRate)
        let duration = Double(samples.count) / rate

        guard useSilero else {
            let speech = EnergyVAD.speechRanges(samples: samples, sampleRate: rate)
            progress(1)
            return Result(speech: speech, usedSilero: false, note: nil)
        }

        do {
            let probabilities = try await sileroProbabilities(samples: samples, progress: progress)
            try Task.checkCancellation()
            let frameLength = Int(rate * 0.02)
            let levels = samples.withUnsafeBufferPointer { EnergyVAD.frameLevels($0, frameLength: frameLength) }
            let speech = SpeechSegmenter.speechRanges(
                probabilities: probabilities,
                hop: Double(VadManager.chunkSize) / rate,
                levels: levels,
                frameDuration: Double(frameLength) / rate,
                duration: duration)
            progress(1)
            return Result(speech: speech, usedSilero: true, note: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let speech = EnergyVAD.speechRanges(samples: samples, sampleRate: rate)
            progress(1)
            return Result(
                speech: speech, usedSilero: false,
                note: "Silero VAD не загрузился, паузы найдены по громкости. Границы могут быть менее точными.")
        }
    }

    private static func sileroProbabilities(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Float] {
        // Модель (~2 МБ) скачивается при первом запуске.
        let manager = try await VadManager(config: VadConfig())

        // Кормим кусками по ~2 минуты, чтобы показывать прогресс и реагировать на отмену.
        // Размер куска кратен окну модели, поэтому сетка вероятностей не сбивается.
        let chunkSamples = VadManager.chunkSize * 480
        var probabilities: [Float] = []
        probabilities.reserveCapacity(samples.count / VadManager.chunkSize + 1)
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, offset + chunkSamples)
            let results = try await manager.process(Array(samples[offset..<end]))
            probabilities.append(contentsOf: results.map(\.probability))
            offset = end
            progress(Double(offset) / Double(samples.count))
        }
        return probabilities
    }
}
