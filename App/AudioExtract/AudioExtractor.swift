@preconcurrency import AVFoundation
import Foundation

/// Достаёт звук из видео: AVAssetReader → 16 кГц, моно, Float32, сырым потоком во временный файл.
enum AudioExtractor {
    static let sampleRate = 16_000

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).f32")
    }

    /// - Returns: число записанных сэмплов.
    @discardableResult
    static func extract(
        from videoURL: URL, to outputURL: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = try await pickTrack(tracks) else {
            throw AppError("Нет звука", "В видео нет звуковой дорожки, а паузы и дубли ищутся по речи.")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AppError("Звук не читается", "Не получилось прочитать звуковую дорожку этого видео.")
        }
        reader.add(output)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        guard reader.startReading() else {
            throw AppError.wrap(reader.error ?? CocoaError(.fileReadUnknown), title: "Звук не читается")
        }

        var written = 0
        var isFirst = true
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

            // Звук может начинаться не с нуля. Добиваем тишиной, чтобы таймкоды совпадали с видео.
            if isFirst {
                isFirst = false
                if pts.isFinite, pts > 0.001 {
                    let padding = Int((pts * Double(sampleRate)).rounded())
                    try handle.write(contentsOf: Data(count: padding * MemoryLayout<Float>.size))
                    written += padding
                }
            }

            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            try handle.write(contentsOf: data)
            written += length / MemoryLayout<Float>.size

            if duration > 0, pts.isFinite { progress(min(1, max(0, pts / duration))) }
        }

        if reader.status == .failed {
            throw AppError.wrap(reader.error ?? CocoaError(.fileReadUnknown), title: "Звук не читается")
        }
        guard written > sampleRate / 2 else {
            throw AppError("Нет звука", "Звуковая дорожка пустая или слишком короткая.")
        }
        progress(1)
        return written
    }

    /// Обычная стерео- или монодорожка предпочтительнее пространственной (у неё 4 канала и больше).
    private static func pickTrack(_ tracks: [AVAssetTrack]) async throws -> AVAssetTrack? {
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            let channels = descriptions.first?.audioStreamBasicDescription?.mChannelsPerFrame ?? 2
            if channels <= 2 { return track }
        }
        return tracks.first
    }

    /// Читает сэмплы с диска. 15 минут звука занимают около 58 МБ.
    static func loadSamples(from url: URL) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let count = size / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        var offset = 0
        let chunkBytes = 4 << 20
        while offset < count {
            guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
            let floats = data.count / MemoryLayout<Float>.size
            let copied = min(floats, count - offset)
            samples.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    destination.baseAddress!.advanced(by: offset * MemoryLayout<Float>.size)
                        .copyMemory(from: source.baseAddress!, byteCount: copied * MemoryLayout<Float>.size)
                }
            }
            offset += copied
        }
        if offset < count { samples.removeSubrange(offset..<count) }
        return samples
    }
}
