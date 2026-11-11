@preconcurrency import AVFoundation
import CutCore
import Foundation
import VideoToolbox

/// Экспорт готового ролика: полное перекодирование в HEVC аппаратным кодером через AVAssetWriter.
enum VideoExporter {

    static func export(
        sourceURL: URL, cuts: [TimeRange], outputURL: URL, bitrate: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let builder = try await CompositionBuilder.load(url: sourceURL)
        let built = try builder.make(cuts: cuts)
        let totalDuration = built.composition.duration.seconds

        // Место: видео плюс звук с запасом. Оптимизация под сеть на время удваивает размер файла.
        let estimated = Int64(Double(bitrate + 256_000) / 8 * totalDuration * 1.15)
        try Disk.ensure(estimated * 2 + (50 << 20))

        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: built.composition)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // Видео.
        let is10Bit = Self.is10Bit(builder.videoFormat)
        let pixelFormat =
            is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: built.videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw failure("Видеодорожка не читается.") }
        reader.add(videoOutput)

        let fps = builder.fps
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(abs(builder.naturalSize.width).rounded()),
            AVVideoHeightKey: Int(abs(builder.naturalSize.height).rounded()),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey:
                    (is10Bit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
                    as String,
            ] as [String: Any],
        ]
        if let color = Self.colorProperties(builder.videoFormat) {
            videoSettings[AVVideoColorPropertiesKey] = color
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw failure("Кодер HEVC не принял параметры этого видео.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Кадры пишем как есть, поворот задаётся матрицей: вертикальное видео остаётся вертикальным.
        videoInput.transform = builder.preferredTransform
        guard writer.canAdd(videoInput) else { throw failure("Не получилось настроить запись видео.") }
        writer.add(videoInput)

        // Звук.
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !built.audioTracks.isEmpty {
            let description = builder.audioFormat?.audioStreamBasicDescription
            let sourceRate = description?.mSampleRate ?? 48000
            let sampleRate = sourceRate == 44100 ? 44100.0 : 48000.0
            let channels = min(2, max(1, Int(description?.mChannelsPerFrame ?? 2)))

            let output = AVAssetReaderAudioMixOutput(
                audioTracks: built.audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            output.audioMix = built.audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw failure("Звуковая дорожка не читается.") }
            reader.add(output)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000,
            ]
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw failure("Кодер AAC не принял параметры звука.")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw failure("Не получилось настроить запись звука.") }
            writer.add(input)
            audioOutput = output
            audioInput = input
        }

        guard reader.startReading() else { throw wrap(reader.error) }
        guard writer.startWriting() else { throw wrap(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let cancelled = CancelFlag()
        let videoPump = UncheckedBox((videoInput, videoOutput as AVAssetReaderOutput))
        let audioPump = UncheckedBox(audioInput.flatMap { input in audioOutput.map { (input, $0 as AVAssetReaderOutput) } })

        let finished = await withTaskCancellationHandler {
            async let videoDone = pump(
                videoPump, queue: DispatchQueue(label: "export.video"), cancelled: cancelled
            ) { time in
                if totalDuration > 0 { progress(min(1, max(0, time.seconds / totalDuration))) }
            }
            async let audioDone = pumpIfPresent(audioPump, queue: DispatchQueue(label: "export.audio"), cancelled: cancelled)
            let results = await (videoDone, audioDone)
            return results.0 && results.1
        } onCancel: {
            cancelled.set()
        }

        if cancelled.isSet || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
        guard finished, reader.status != .failed else {
            let error = reader.error ?? writer.error
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw wrap(error)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw wrap(writer.error)
        }
        progress(1)
    }

    // MARK: - Перекачка сэмплов

    private final class PumpState: @unchecked Sendable {
        var done = false
    }

    /// Перекладывает сэмплы из ридера в райтер. Возвращает false при ошибке или отмене.
    private static func pumpIfPresent(
        _ pair: UncheckedBox<(AVAssetWriterInput, AVAssetReaderOutput)?>, queue: DispatchQueue,
        cancelled: CancelFlag
    ) async -> Bool {
        guard let value = pair.value else { return true }
        return await pump(UncheckedBox(value), queue: queue, cancelled: cancelled)
    }

    private static func pump(
        _ pair: UncheckedBox<(AVAssetWriterInput, AVAssetReaderOutput)>, queue: DispatchQueue,
        cancelled: CancelFlag, onSample: (@Sendable (CMTime) -> Void)? = nil
    ) async -> Bool {
        let state = PumpState()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let (input, output) = pair.value
            let box = UncheckedBox((input, output))
            input.requestMediaDataWhenReady(on: queue) {
                let (input, output) = box.value
                guard !state.done else { return }

                func finish(_ success: Bool) {
                    state.done = true
                    input.markAsFinished()
                    continuation.resume(returning: success)
                }

                while input.isReadyForMoreMediaData {
                    if cancelled.isSet { return finish(false) }
                    guard let sample = output.copyNextSampleBuffer() else { return finish(true) }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) { return finish(false) }
                }
            }
        }
    }

    // MARK: - Формат исходника

    private static func is10Bit(_ format: CMFormatDescription?) -> Bool {
        guard let format else { return false }
        if let bits = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber
        {
            return bits.intValue > 8
        }
        if let transfer = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        {
            return transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        }
        return false
    }

    /// Цветовые параметры переносим из исходника, иначе HDR-видео (HLG) потускнеет.
    private static func colorProperties(_ format: CMFormatDescription?) -> [String: Any]? {
        guard let format,
            let primaries = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
            let transfer = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
            let matrix = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    // MARK: - Ошибки

    private static func failure(_ message: String) -> AppError {
        AppError("Экспорт не удался", message)
    }

    private static func wrap(_ error: (any Error)?) -> AppError {
        guard let error else { return failure("Кодер остановился без объяснения причин. Попробуй ещё раз.") }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: nsError.code) {
            case .diskFull:
                return AppError("Мало места", "Во время экспорта закончилось место. Освободи память и попробуй снова.")
            case .operationInterrupted, .sessionWasInterrupted:
                return failure("Экспорт прерван: приложение было свёрнуто или экран заблокирован. Запусти его ещё раз и не сворачивай приложение.")
            default:
                break
            }
        }
        return failure("Кодер сообщил об ошибке: \(nsError.localizedDescription)")
    }
}
