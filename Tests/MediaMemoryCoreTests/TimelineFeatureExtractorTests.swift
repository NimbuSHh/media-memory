@preconcurrency import AVFoundation
import CoreVideo
import Foundation
@testable import MediaMemoryCore
import XCTest

final class TimelineFeatureExtractorTests: XCTestCase {
    func testExtractsVisualChangeAtDecodedSamplePTSAndAcceptsMissingAudio() async throws {
        let fixture = try TimelineFixtureDirectory()
        let video = fixture.url.appending(path: "visual-only.mov")
        try await writeVideo(
            to: video,
            durationSeconds: 3,
            changeTimeSeconds: 1.5
        )
        let before = try FileFingerprint.snapshot(for: video)

        let result = try await TimelineFeatureExtractor.extract(
            assetURL: video,
            configuration: .init(
                visualSampleIntervalMS: 100,
                visualChangeThreshold: 0.15,
                minimumVisualCandidateSpacingMS: 300
            )
        )
        let after = try FileFingerprint.snapshot(for: video)

        XCTAssertEqual(after, before, "时间轴预分析必须只读源视频")
        XCTAssertTrue(result.silenceEnds.isEmpty, "没有音轨不是提取失败")
        let visual = try XCTUnwrap(result.visualChanges.first)
        XCTAssertEqual(result.visualChanges.count, 1)
        XCTAssertTrue((1_450...1_650).contains(visual.timeMS), "候选应使用解码帧 PTS")
        guard case let .visualChange(score, previousSampleTimeMS) = visual.evidence else {
            return XCTFail("候选类型错误")
        }
        XCTAssertGreaterThan(score, 0.8)
        XCTAssertLessThan(previousSampleTimeMS, visual.timeMS)
        XCTAssertLessThanOrEqual(visual.timeMS - previousSampleTimeMS, 150)
    }

    func testExtractsSilenceEndFromDecodedAudioEnergy() async throws {
        let fixture = try TimelineFixtureDirectory()
        let videoOnly = fixture.url.appending(path: "video.mov")
        let audioOnly = fixture.url.appending(path: "audio.wav")
        let combined = fixture.url.appending(path: "combined.mov")
        try await writeVideo(
            to: videoOnly,
            durationSeconds: 4,
            changeTimeSeconds: 2
        )
        try writeWAV(
            to: audioOnly,
            durationSeconds: 4,
            silentRange: 1..<2
        )
        try await combine(video: videoOnly, audio: audioOnly, destination: combined)

        let result = try await TimelineFeatureExtractor.extract(
            assetURL: combined,
            configuration: .init(
                visualSampleIntervalMS: 250,
                silenceThresholdDBFS: -35,
                minimumSilenceDurationMS: 700
            )
        )

        let silence = try XCTUnwrap(result.silenceEnds.first)
        XCTAssertEqual(result.silenceEnds.count, 1)
        XCTAssertTrue((1_900...2_150).contains(silence.timeMS))
        guard case let .silenceEnd(startTimeMS, durationMS) = silence.evidence else {
            return XCTFail("候选类型错误")
        }
        XCTAssertTrue((900...1_100).contains(startTimeMS))
        XCTAssertGreaterThanOrEqual(durationMS, 800)
        XCTAssertEqual(result.candidates.map(\.timeMS), result.candidates.map(\.timeMS).sorted())
    }

    func testAlreadyCancelledTaskDoesNotContinueReading() async throws {
        let fixture = try TimelineFixtureDirectory()
        let video = fixture.url.appending(path: "cancel.mov")
        try await writeVideo(to: video, durationSeconds: 3, changeTimeSeconds: 1.5)

        let task = Task {
            return try await TimelineFeatureExtractor.extract(assetURL: video)
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("已取消任务不应完成全量读取")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testExtremePublicConfigurationIsBoundedInsteadOfOverflowing() async throws {
        let fixture = try TimelineFixtureDirectory()
        let video = fixture.url.appending(path: "bounded.mov")
        try await writeVideo(to: video, durationSeconds: 1, changeTimeSeconds: 0.5)

        let result = try await TimelineFeatureExtractor.extract(
            assetURL: video,
            configuration: .init(
                visualSampleIntervalMS: Int64.max,
                visualChangeThreshold: .infinity,
                minimumVisualCandidateSpacingMS: Int64.max,
                analysisWidth: Int.max,
                analysisHeight: Int.max,
                audioAnalysisWindowMS: Int64.max,
                silenceThresholdDBFS: .nan,
                minimumSilenceDurationMS: Int64.max
            )
        )

        XCTAssertGreaterThan(result.durationMS, 0)
    }

    func testThreeHourVisualSamplingIsCappedAndBatched() {
        let configuration = TimelineFeatureExtractor.normalizedConfiguration(.init())
        let durationMS: Int64 = 3 * 60 * 60 * 1_000
        let interval = TimelineFeatureExtractor.effectiveVisualSampleIntervalMS(
            durationMS: durationMS,
            configuration: configuration
        )
        let count = TimelineFeatureExtractor.visualSampleCount(
            durationMS: durationMS,
            configuration: configuration
        )

        XCTAssertEqual(count, configuration.maximumVisualSampleCount)
        XCTAssertEqual(interval, 1_500)
        XCTAssertLessThanOrEqual(configuration.visualRequestBatchSize, 240)
    }

    func testPCMWindowsDoNotDependOnReaderBufferPacketization() throws {
        let samples = [Int16](repeating: 0, count: 3_500)
        var single = TimelineFeatureExtractor.PCMEnergyAccumulator(
            sampleRate: 16_000,
            windowDurationMS: 100
        )
        let singleBatch = try single.append(samples, at: 0)
        let singleWindows = singleBatch.windows + [try single.trailingWindow()].compactMap { $0 }

        var chunked = TimelineFeatureExtractor.PCMEnergyAccumulator(
            sampleRate: 16_000,
            windowDurationMS: 100
        )
        var chunkedWindows: [TimelineFeatureExtractor.AudioEnergyWindow] = []
        var offset = 0
        for size in [500, 700, 2_300] {
            let batch = try chunked.append(
                Array(samples[offset..<(offset + size)]),
                at: Int64(offset)
            )
            XCTAssertNil(batch.discontinuityEndMS)
            chunkedWindows.append(contentsOf: batch.windows)
            offset += size
        }
        if let trailing = try chunked.trailingWindow() { chunkedWindows.append(trailing) }

        XCTAssertEqual(chunkedWindows, singleWindows)
    }

    func testPCMWindowResetsAtPTSDiscontinuityUsingActualSampleRate() throws {
        var accumulator = TimelineFeatureExtractor.PCMEnergyAccumulator(
            sampleRate: 48_000,
            windowDurationMS: 100
        )
        _ = try accumulator.append([Int16](repeating: 0, count: 2_400), at: 0)
        let afterGap = try accumulator.append(
            [Int16](repeating: 0, count: 4_800),
            at: 4_800
        )

        XCTAssertEqual(afterGap.precedingDiscontinuityWindow?.startMS, 0)
        XCTAssertEqual(afterGap.precedingDiscontinuityWindow?.endMS, 50)
        XCTAssertEqual(afterGap.discontinuityEndMS, 50)
        XCTAssertEqual(afterGap.windows.first?.startMS, 100)
        XCTAssertEqual(afterGap.windows.first?.endMS, 200)

        var malformed = TimelineFeatureExtractor.PCMEnergyAccumulator(
            sampleRate: 48_000,
            windowDurationMS: 100
        )
        XCTAssertThrowsError(
            try malformed.append([0, 0], at: Int64.max)
        ) { error in
            guard let extractionError = error as? TimelineFeatureExtractionError,
                  case .invalidTimestamp = extractionError else {
                return XCTFail("溢出必须转为 invalidTimestamp")
            }
        }
    }
}

private func writeVideo(
    to url: URL,
    durationSeconds: Int,
    changeTimeSeconds: Double
) async throws {
    let width = 320
    let height = 180
    let framesPerSecond: Int32 = 10
    let frameCount = durationSeconds * Int(framesPerSecond)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 300_000,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )
    guard writer.canAdd(input) else {
        throw TimelineFixtureError.cannotWrite("不能添加视频输入")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw TimelineFixtureError.cannotWrite(writer.error?.localizedDescription ?? "启动失败")
    }
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw TimelineFixtureError.cannotWrite("像素缓冲池不可用")
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
            throw TimelineFixtureError.cannotWrite("不能创建像素缓冲")
        }
        let timeSeconds = Double(frameIndex) / Double(framesPerSecond)
        fill(pixelBuffer, gray: timeSeconds < changeTimeSeconds ? 0 : 255)
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)
        ) else {
            throw TimelineFixtureError.cannotWrite(writer.error?.localizedDescription ?? "追加帧失败")
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw TimelineFixtureError.cannotWrite(writer.error?.localizedDescription ?? "完成失败")
    }
}

private func fill(_ pixelBuffer: CVPixelBuffer, gray: UInt8) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            bytes[offset] = gray
            bytes[offset + 1] = gray
            bytes[offset + 2] = gray
            bytes[offset + 3] = 255
        }
    }
}

private func writeWAV(
    to url: URL,
    durationSeconds: Int,
    silentRange: Range<Double>
) throws {
    let sampleRate: UInt32 = 16_000
    let sampleCount = durationSeconds * Int(sampleRate)
    var pcm = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
    for index in 0..<sampleCount {
        let time = Double(index) / Double(sampleRate)
        let value: Int16
        if silentRange.contains(time) {
            value = 0
        } else {
            value = Int16((sin(time * 2 * .pi * 440) * 8_000).rounded())
        }
        appendLittleEndian(value, to: &pcm)
    }

    var wav = Data()
    wav.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    appendLittleEndian(UInt32(16), to: &wav)
    appendLittleEndian(UInt16(1), to: &wav)
    appendLittleEndian(UInt16(1), to: &wav)
    appendLittleEndian(sampleRate, to: &wav)
    appendLittleEndian(sampleRate * 2, to: &wav)
    appendLittleEndian(UInt16(2), to: &wav)
    appendLittleEndian(UInt16(16), to: &wav)
    wav.append(contentsOf: "data".utf8)
    appendLittleEndian(UInt32(pcm.count), to: &wav)
    wav.append(pcm)
    try wav.write(to: url, options: .atomic)
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func combine(video: URL, audio: URL, destination: URL) async throws {
    let videoAsset = AVURLAsset(url: video)
    let audioAsset = AVURLAsset(url: audio)
    let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
    let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let videoTrack = try XCTUnwrap(videoTracks.first)
    let audioTrack = try XCTUnwrap(audioTracks.first)
    let videoDuration = try await videoAsset.load(.duration)
    let audioDuration = try await audioAsset.load(.duration)
    let duration = CMTimeMinimum(videoDuration, audioDuration)

    let composition = AVMutableComposition()
    let compositionVideo = try XCTUnwrap(
        composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    )
    let compositionAudio = try XCTUnwrap(
        composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    )
    try compositionVideo.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: videoTrack,
        at: .zero
    )
    try compositionAudio.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: audioTrack,
        at: .zero
    )

    let exporter = try XCTUnwrap(
        AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    )
    try await exporter.export(to: destination, as: .mov)
}

private enum TimelineFixtureError: Error {
    case cannotWrite(String)
}

private final class TimelineFixtureDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "media-memory-timeline-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
