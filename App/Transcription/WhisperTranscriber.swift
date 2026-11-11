import CutCore
import Foundation
@preconcurrency import WhisperKit

/// Транскрипция через WhisperKit с таймкодами по словам.
enum WhisperTranscriber {

    enum Phase: Sendable {
        case downloading(Double)
        case loading
        case transcribing(Double)
    }

    /// Скачивает модель при необходимости, распознаёт речь и выгружает модель из памяти перед возвратом.
    static func transcribe(
        samples: [Float], model: WhisperModel, onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws -> [Word] {
        onPhase(.downloading(0))
        let folder: URL
        do {
            folder = try await WhisperKit.download(
                variant: model.rawValue,
                downloadBase: ModelStore.whisper,
                progressCallback: { progress in onPhase(.downloading(progress.fractionCompleted)) })
        } catch {
            throw AppError.wrap(error, title: "Модель Whisper не скачалась")
        }
        try Task.checkCancellation()

        onPhase(.loading)
        let config = WhisperKitConfig(
            downloadBase: ModelStore.whisper,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false)
        nonisolated(unsafe) let whisper: WhisperKit
        do {
            whisper = try await WhisperKit(config)
        } catch {
            throw AppError(
                "Whisper не загрузился",
                "Не получилось загрузить модель распознавания. Попробуй модель полегче в настройках или удали модели и скачай заново. (\(error.localizedDescription))"
            )
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "ru",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad)

        // Прогресс WhisperKit ведёт сам, опрашиваем его со стороны.
        let progress = whisper.progress
        let monitor = Task {
            while !Task.isCancelled {
                onPhase(.transcribing(progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { monitor.cancel() }

        onPhase(.transcribing(0))
        let results: [TranscriptionResult]
        // Колбэк WhisperKit вызывается из его собственных задач, поэтому отмену передаём флагом.
        let cancelled = CancelFlag()
        do {
            results = try await withTaskCancellationHandler {
                try await whisper.transcribe(
                    audioArray: samples,
                    decodeOptions: options,
                    callback: { _ in cancelled.isSet ? false : nil })
            } onCancel: {
                cancelled.set()
            }
        } catch {
            await whisper.unloadModels()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw AppError(
                "Распознавание не удалось", "Whisper не смог обработать звук. (\(error.localizedDescription))")
        }

        // Освобождаем память до загрузки LLM.
        await whisper.unloadModels()
        try Task.checkCancellation()

        var words: [Word] = []
        for result in results {
            for segment in result.segments {
                guard let timings = segment.words, !timings.isEmpty else {
                    // Сегмент без пословных таймкодов: раскладываем слова равномерно.
                    words.append(contentsOf: spread(segment.text, start: Double(segment.start), end: Double(segment.end)))
                    continue
                }
                for timing in timings {
                    words.append(Word(text: timing.word, start: Double(timing.start), end: Double(timing.end)))
                }
            }
        }
        return PhraseSegmenter.sanitize(words)
    }

    private static func spread(_ text: String, start: Double, end: Double) -> [Word] {
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty, end > start else { return [] }
        let step = (end - start) / Double(parts.count)
        return parts.enumerated().map { index, part in
            Word(text: part, start: start + Double(index) * step, end: start + Double(index + 1) * step)
        }
    }
}
