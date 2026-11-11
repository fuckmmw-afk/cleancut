@preconcurrency import AVFoundation
import CutCore
import Foundation

/// Собирает AVMutableComposition из оставшихся кусков исходника.
/// Одна и та же композиция идёт и в плеер на экране ревью, и в экспорт, поэтому превью совпадает с результатом.
final class CompositionBuilder: @unchecked Sendable {

    struct Output: @unchecked Sendable {
        let composition: AVMutableComposition
        let audioMix: AVAudioMix?
        /// Куски исходника, которые вошли в ролик, с границами по кадрам.
        let keeps: [TimeRange]
        let videoTrack: AVMutableCompositionTrack
        let audioTracks: [AVMutableCompositionTrack]
    }

    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let videoRange: CMTimeRange
    let audioRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let fps: Double
    let frameDuration: CMTime
    let videoFormat: CMFormatDescription?
    let audioFormat: CMFormatDescription?

    var duration: Double { videoRange.end.seconds }

    private init(
        asset: AVURLAsset, videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?, videoRange: CMTimeRange,
        audioRange: CMTimeRange, naturalSize: CGSize, preferredTransform: CGAffineTransform, fps: Double,
        videoFormat: CMFormatDescription?, audioFormat: CMFormatDescription?
    ) {
        self.asset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.videoRange = videoRange
        self.audioRange = audioRange
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.fps = fps
        self.frameDuration = Self.frameDuration(forFPS: fps)
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
    }

    static func load(url: URL) async throws -> CompositionBuilder {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("Нет видеодорожки", "В файле нет видео.")
        }
        let (videoRange, naturalSize, transform, frameRate, videoFormats) = try await video.load(
            .timeRange, .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)

        var audio: AVAssetTrack?
        var audioFormat: CMFormatDescription?
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let formats = try await track.load(.formatDescriptions)
            let channels = formats.first?.audioStreamBasicDescription?.mChannelsPerFrame ?? 2
            if audio == nil || channels <= 2 {
                audio = track
                audioFormat = formats.first
                if channels <= 2 { break }
            }
        }
        let audioRange = try await audio?.load(.timeRange) ?? .zero

        return CompositionBuilder(
            asset: asset, videoTrack: video, audioTrack: audio, videoRange: videoRange, audioRange: audioRange,
            naturalSize: naturalSize, preferredTransform: transform,
            fps: frameRate > 0 ? Double(frameRate) : 30,
            videoFormat: videoFormats.first, audioFormat: audioFormat)
    }

    /// Точная длительность кадра для стандартных частот. Айфон пишет 29.98–30.02, это всё 30.
    static func frameDuration(forFPS fps: Double) -> CMTime {
        let standard: [(Double, CMTime)] = [
            (24, CMTime(value: 1, timescale: 24)), (25, CMTime(value: 1, timescale: 25)),
            (30, CMTime(value: 1, timescale: 30)), (50, CMTime(value: 1, timescale: 50)),
            (60, CMTime(value: 1, timescale: 60)), (120, CMTime(value: 1, timescale: 120)),
            (240, CMTime(value: 1, timescale: 240)),
            (24000.0 / 1001, CMTime(value: 1001, timescale: 24000)),
            (30000.0 / 1001, CMTime(value: 1001, timescale: 30000)),
            (60000.0 / 1001, CMTime(value: 1001, timescale: 60000)),
        ]
        if let match = standard.min(by: { abs($0.0 - fps) < abs($1.0 - fps) }), abs(match.0 - fps) / fps < 0.004 {
            return match.1
        }
        return CMTime(seconds: 1 / max(fps, 1), preferredTimescale: 60000)
    }

    /// - Parameters:
    ///   - cuts: итоговые резы в секундах исходника.
    ///   - crossfade: длина аудио-кроссфейда на склейке.
    func make(cuts: [TimeRange], crossfade: Double = 0.016) throws -> Output {
        let frameSeconds = frameDuration.seconds
        let exactFPS = 1 / frameSeconds
        let offset = videoRange.start.seconds
        let length = videoRange.duration.seconds

        // Резы заданы во времени ассета, кадры считаем от начала видеодорожки.
        let shifted = cuts.map { TimeRange(start: $0.start - offset, end: $0.end - offset) }
        let keeps = CutPlanner.snapToFrames(
            CutPlanner.keeps(cuts: shifted, duration: length), fps: exactFPS, duration: length)
        guard !keeps.isEmpty else {
            throw AppError("Нечего показывать", "Вырезано всё видео. Верни хотя бы одну фразу.")
        }

        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AppError("Ошибка монтажа", "Не получилось собрать видеодорожку.") }
        video.preferredTransform = preferredTransform

        // Две звуковые дорожки в шахматном порядке: соседние куски перекрываются на длину кроссфейда.
        var audioTracks: [AVMutableCompositionTrack] = []
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        if audioTrack != nil {
            for _ in 0..<min(2, keeps.count) {
                guard
                    let track = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                audioTracks.append(track)
                mixParameters.append(AVMutableAudioMixInputParameters(track: track))
            }
        }

        func frameTime(_ seconds: Double) -> CMTime {
            let frames = Int64((seconds / frameSeconds).rounded())
            return CMTimeAdd(
                videoRange.start,
                CMTime(value: frames * frameDuration.value, timescale: frameDuration.timescale))
        }

        let half = CMTime(seconds: crossfade / 2, preferredTimescale: 48000)
        var cursor = CMTime.zero
        var placed: [TimeRange] = []

        for (index, keep) in keeps.enumerated() {
            let start = frameTime(keep.start)
            let end = CMTimeMinimum(frameTime(keep.end), videoRange.end)
            guard end > start else { continue }
            let range = CMTimeRange(start: start, end: end)
            try video.insertTimeRange(range, of: videoTrack, at: cursor)
            placed.append(TimeRange(start: start.seconds, end: end.seconds))

            if let audioTrack, !audioTracks.isEmpty {
                let slot = index % audioTracks.count
                // Захватываем по половине кроссфейда из вырезанного материала с каждой стороны склейки.
                var audioStart = index > 0 ? CMTimeSubtract(start, half) : start
                var audioEnd = index < keeps.count - 1 ? CMTimeAdd(end, half) : end
                audioStart = CMTimeMaximum(audioStart, audioRange.start)
                audioEnd = CMTimeMinimum(audioEnd, audioRange.end)
                let lead = CMTimeMaximum(.zero, CMTimeSubtract(start, audioStart))
                let tail = CMTimeMaximum(.zero, CMTimeSubtract(audioEnd, end))

                if audioEnd > audioStart, CMTimeSubtract(cursor, lead) >= .zero {
                    let at = CMTimeSubtract(cursor, lead)
                    try audioTracks[slot].insertTimeRange(
                        CMTimeRange(start: audioStart, end: audioEnd), of: audioTrack, at: at)

                    let parameters = mixParameters[slot]
                    if lead > .zero {
                        parameters.setVolumeRamp(
                            fromStartVolume: 0, toEndVolume: 1,
                            timeRange: CMTimeRange(start: at, duration: CMTimeMultiply(lead, multiplier: 2)))
                    } else if index > 0 {
                        parameters.setVolume(1, at: at)
                    }
                    if tail > .zero {
                        let junction = CMTimeAdd(cursor, range.duration)
                        parameters.setVolumeRamp(
                            fromStartVolume: 1, toEndVolume: 0,
                            timeRange: CMTimeRange(
                                start: CMTimeSubtract(junction, tail), duration: CMTimeMultiply(tail, multiplier: 2)))
                    }
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        // Пустые дорожки ломают AVAssetReader.
        for track in audioTracks where track.segments.isEmpty {
            composition.removeTrack(track)
        }
        let usedAudio = audioTracks.filter { !$0.segments.isEmpty }
        var audioMix: AVAudioMix?
        if !usedAudio.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters.filter { parameters in
                usedAudio.contains { $0.trackID == parameters.trackID }
            }
            audioMix = mix
        }

        // Возвращаем куски во времени ассета, чтобы карта времени совпадала с транскриптом.
        return Output(
            composition: composition, audioMix: audioMix, keeps: placed, videoTrack: video,
            audioTracks: usedAudio)
    }
}
