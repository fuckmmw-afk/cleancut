@preconcurrency import AVFoundation
import CutCore
import XCTest

@testable import CleanCut

/// Сквозная проверка без нейросетей: синтетическое вертикальное видео → импорт → звук → паузы →
/// композиция → экспорт. Проверяет то, что нельзя покрыть тестами CutCore: работу с AVFoundation.
final class PipelineIntegrationTests: XCTestCase {
    static let fps = 30
    static let duration = 6.5
    /// Интервалы «речи» (тон 300 Гц), остальное тишина.
    static let tones: [(Double, Double)] = [(1.0, 2.0), (3.5, 4.5), (4.8, 5.6)]

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cleancut-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func testFullPipelineWithoutModels() async throws {
        let sourceURL = workDirectory.appendingPathComponent("source.mov")
        try await TestVideo.write(to: sourceURL, duration: Self.duration, fps: Self.fps, tones: Self.tones)

        // Импорт: параметры видео с учётом поворота.
        let info = try await VideoImporter.probe(sourceURL)
        XCTAssertEqual(info.duration, Self.duration, accuracy: 0.1)
        XCTAssertEqual(info.fps, Double(Self.fps), accuracy: 0.5)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 568)

        // Звук: 16 кГц моно.
        let audioURL = AudioExtractor.temporaryURL()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let written = try await AudioExtractor.extract(from: sourceURL, to: audioURL) { _ in }
        let samples = try AudioExtractor.loadSamples(from: audioURL)
        XCTAssertEqual(samples.count, written)
        XCTAssertEqual(Double(samples.count) / 16000, Self.duration, accuracy: 0.15)

        // Паузы по громкости: должны найтись все три куска тона.
        let detection = try await SpeechDetector.detect(samples: samples, useSilero: false) { _ in }
        XCTAssertFalse(detection.usedSilero)
        XCTAssertEqual(detection.speech.count, 3, "\(detection.speech)")
        for (range, tone) in zip(detection.speech, Self.tones) {
            XCTAssertEqual(range.start, tone.0, accuracy: 0.08)
            XCTAssertEqual(range.end, tone.1, accuracy: 0.08)
        }

        // Резы: начало, середина и хвост. Пауза 0.3 с между вторым и третьим тоном остаётся.
        let options = CutPlanner.Options()
        let pauses = CutPlanner.pauseCuts(speech: detection.speech, duration: info.duration, options: options)
        let cuts = CutPlanner.finalCuts(pauses, duration: info.duration, options: options)
        XCTAssertEqual(cuts.count, 3, "\(cuts)")

        // Композиция: границы по кадрам, длительность равна сумме кусков.
        let builder = try await CompositionBuilder.load(url: sourceURL)
        let built = try builder.make(cuts: cuts)
        XCTAssertEqual(built.keeps.count, 2)
        let keptSeconds = built.keeps.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(built.composition.duration.seconds, keptSeconds, accuracy: 0.001)
        XCTAssertEqual(keptSeconds, 3.58, accuracy: 0.25)
        for keep in built.keeps {
            let frames = keep.start * Double(Self.fps)
            XCTAssertEqual(frames, frames.rounded(), accuracy: 0.001, "рез не на границе кадра: \(keep)")
        }
        XCTAssertNotNil(built.audioMix)
        XCTAssertEqual(built.audioTracks.count, 2)
        let expectedFrames = Int((keptSeconds * Double(Self.fps)).rounded())

        // Экспорт.
        let outputURL = workDirectory.appendingPathComponent("out.mp4")
        let lastProgress = ProgressBox()
        try await VideoExporter.export(
            sourceURL: sourceURL, cuts: cuts, outputURL: outputURL, bitrate: 2_000_000
        ) { lastProgress.set($0) }
        XCTAssertEqual(lastProgress.value, 1, accuracy: 0.001)

        let output = AVURLAsset(url: outputURL)
        let outputDuration = try await output.load(.duration).seconds
        XCTAssertEqual(outputDuration, keptSeconds, accuracy: 0.08)

        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let (size, transform, rate, formats) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        XCTAssertEqual(size.width, 568)
        XCTAssertEqual(size.height, 320)
        XCTAssertEqual(Double(rate), Double(Self.fps), accuracy: 0.5)
        // Поворот сохранён: кадр после применения матрицы вертикальный.
        let oriented = size.applying(transform)
        XCTAssertEqual(abs(oriented.width), 320, accuracy: 0.5)
        XCTAssertEqual(abs(oriented.height), 568, accuracy: 0.5)
        let codec = try XCTUnwrap(formats.first).mediaSubType
        XCTAssertEqual(codec, .hevc)

        // Точность по кадру: в ролике ровно столько кадров, сколько оставлено.
        let frameCount = try countSamples(in: output, track: video)
        XCTAssertEqual(frameCount, expectedFrames)

        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioFormats = try await audio.load(.formatDescriptions)
        XCTAssertEqual(audioFormats.first?.mediaSubType, .mpeg4AAC)

        // Звук экспортированного ролика: тишины по краям и в середине больше нет.
        let outAudioURL = AudioExtractor.temporaryURL()
        defer { try? FileManager.default.removeItem(at: outAudioURL) }
        try await AudioExtractor.extract(from: outputURL, to: outAudioURL) { _ in }
        let outSamples = try AudioExtractor.loadSamples(from: outAudioURL)
        let outSpeech = EnergyVAD.speechRanges(samples: outSamples, sampleRate: 16000)
        let silences = CutPlanner.complement(of: outSpeech, duration: Double(outSamples.count) / 16000)
        XCTAssertTrue(silences.allSatisfy { $0.duration < 0.5 }, "остались длинные паузы: \(silences)")
    }

    func testImportCopiesIntoProjectFolder() async throws {
        let sourceURL = workDirectory.appendingPathComponent("My clip.mov")
        try await TestVideo.write(to: sourceURL, duration: 2, fps: Self.fps, tones: [(0.5, 1.5)])

        let project = try await VideoImporter.importVideo(.external(sourceURL))
        defer { try? FileManager.default.removeItem(at: ProjectStore.directory(for: project.id)) }

        XCTAssertEqual(project.title, "My clip")
        XCTAssertEqual(project.stage, .imported)
        XCTAssertEqual(project.duration, 2, accuracy: 0.1)
        XCTAssertEqual(project.width, 320)
        XCTAssertEqual(project.height, 568)
        let copied = ProjectStore.sourceURL(for: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(Disk.fileSize(copied), Disk.fileSize(sourceURL))
        XCTAssertEqual(project.fileSize, Disk.fileSize(sourceURL))
    }

    func testExportWithoutCutsKeepsEveryFrame() async throws {
        let sourceURL = workDirectory.appendingPathComponent("plain.mov")
        try await TestVideo.write(to: sourceURL, duration: 1.5, fps: Self.fps, tones: [(0.2, 1.3)])
        let outputURL = workDirectory.appendingPathComponent("plain-out.mp4")
        try await VideoExporter.export(sourceURL: sourceURL, cuts: [], outputURL: outputURL, bitrate: 2_000_000) {
            _ in
        }
        let output = AVURLAsset(url: outputURL)
        let tracks = try await output.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        XCTAssertEqual(try countSamples(in: output, track: video), 45)
    }

    func testExportCanBeCancelled() async throws {
        let sourceURL = workDirectory.appendingPathComponent("long.mov")
        try await TestVideo.write(to: sourceURL, duration: 8, fps: Self.fps, tones: [(1, 7)])
        let outputURL = workDirectory.appendingPathComponent("cancelled.mp4")
        let task = Task {
            try await VideoExporter.export(sourceURL: sourceURL, cuts: [], outputURL: outputURL, bitrate: 2_000_000) {
                _ in
            }
        }
        task.cancel()
        do {
            try await task.value
            // Экспорт короткого ролика мог успеть завершиться до отмены, это не ошибка.
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    private func countSamples(in asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(reader.status, .completed)
        return count
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }
    func increment(by amount: Int = 1) { lock.withLock { stored += amount } }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double { lock.withLock { stored } }
    func set(_ value: Double) { lock.withLock { stored = value } }
}

/// Пишет короткое видео: 568×320 с поворотом на 90° (как вертикальная съёмка на айфон) и тоном вместо речи.
enum TestVideo {
    static let sampleRate = 48000

    static func write(to url: URL, duration: Double, fps: Int, tones: [(Double, Double)]) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 568,
                AVVideoHeightKey: 320,
            ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 568,
                kCVPixelBufferHeightKey as String: 320,
            ])
        writer.add(videoInput)

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((duration * Double(fps)).rounded())
        let totalSamples = Int(duration * Double(sampleRate))
        let chunk = sampleRate / 10
        let failures = Counter()

        // Видео: цвет кадра меняется, чтобы кодеру было что сжимать.
        let videoBox = UncheckedBox((videoInput, adaptor))
        let frames = Counter()
        async let videoDone: Void = feed(UncheckedBox(videoInput), queue: DispatchQueue(label: "test.video")) {
            let (_, adaptor) = videoBox.value
            let frame = frames.value
            guard frame < frameCount else { return false }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else {
                failures.increment()
                return false
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else {
                failures.increment()
                return false
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let length = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
                memset(base, Int32((frame * 5) % 256), length)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            if !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) {
                failures.increment()
                return false
            }
            frames.increment()
            return true
        }

        // Звук: тон 300 Гц внутри заданных интервалов.
        let audioBox = UncheckedBox(audioInput)
        let written = Counter()
        let toneRanges = tones.map { TimeRange(start: $0.0, end: $0.1) }
        async let audioDone: Void = feed(audioBox, queue: DispatchQueue(label: "test.audio")) {
            let position = written.value
            guard position < totalSamples else { return false }
            let count = min(chunk, totalSamples - position)
            var pcm = [Int16](repeating: 0, count: count)
            for index in 0..<count {
                let time = Double(position + index) / Double(sampleRate)
                if toneRanges.contains(where: { $0.contains(time) }) {
                    pcm[index] = Int16(9000 * sin(2 * Double.pi * 300 * time))
                }
            }
            guard let buffer = try? audioBuffer(pcm, at: position), audioBox.value.append(buffer) else {
                failures.increment()
                return false
            }
            written.increment(by: count)
            return true
        }
        _ = await (videoDone, audioDone)
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(frames.value, frameCount)

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    /// Кормит вход райтера, пока `next` возвращает true.
    private static func feed(
        _ input: UncheckedBox<AVAssetWriterInput>, queue: DispatchQueue, next: @escaping @Sendable () -> Bool
    ) async {
        let finished = Counter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.value.requestMediaDataWhenReady(on: queue) {
                guard finished.value == 0 else { return }
                while input.value.isReadyForMoreMediaData {
                    if !next() {
                        finished.increment()
                        input.value.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    private static func audioBuffer(_ pcm: [Int16], at position: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        let byteCount = pcm.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let blockBuffer = try XCTUnwrap(block)
        pcm.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: try XCTUnwrap(format),
            sampleCount: pcm.count,
            presentationTimeStamp: CMTime(value: Int64(position), timescale: Int32(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
