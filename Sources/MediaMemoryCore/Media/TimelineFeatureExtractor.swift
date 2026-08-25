@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// A time-localized piece of evidence that may justify a semantic segment boundary.
///
/// The extractor deliberately does not decide segment boundaries. A later planner can
/// combine these candidates with transcript sentence boundaries and OCR changes.
public struct TimelineFeatureCandidate: Equatable, Sendable {
    public enum Evidence: Equatable, Sendable {
        /// The current sampled frame differs from the preceding sampled frame.
        /// `previousSampleTimeMS...timeMS` is the interval in which the change occurred.
        case visualChange(score: Double, previousSampleTimeMS: Int64)

        /// Audio remained below the configured energy threshold and has now ended.
        case silenceEnd(startTimeMS: Int64, durationMS: Int64)
    }

    /// Source-media time. This is always derived from decoded sample PTS.
    public let timeMS: Int64
    public let evidence: Evidence

    public init(timeMS: Int64, evidence: Evidence) {
        self.timeMS = timeMS
        self.evidence = evidence
    }
}

public struct TimelineFeatureExtractionResult: Equatable, Sendable {
    public let durationMS: Int64
    public let candidates: [TimelineFeatureCandidate]

    public init(durationMS: Int64, candidates: [TimelineFeatureCandidate]) {
        self.durationMS = durationMS
        self.candidates = candidates
    }

    public var visualChanges: [TimelineFeatureCandidate] {
        candidates.filter {
            if case .visualChange = $0.evidence { return true }
            return false
        }
    }

    public var silenceEnds: [TimelineFeatureCandidate] {
        candidates.filter {
            if case .silenceEnd = $0.evidence { return true }
            return false
        }
    }
}

public struct TimelineFeatureExtractionConfiguration: Equatable, Sendable {
    /// How often a low-resolution source frame is requested. Returned actual PTS,
    /// rather than request time or encoded key-frame metadata, locates the candidate.
    public var visualSampleIntervalMS: Int64
    /// Combined pixel and luminance-histogram distance in the range `0...1`.
    public var visualChangeThreshold: Double
    /// Prevents several adjacent samples around one cut becoming separate candidates.
    public var minimumVisualCandidateSpacingMS: Int64
    /// Size of the small luminance image used only for change measurement.
    public var analysisWidth: Int
    public var analysisHeight: Int
    /// Maximum PCM energy-window duration. Reader output buffers may span much
    /// longer periods and therefore must not be classified using one aggregate RMS.
    public var audioAnalysisWindowMS: Int64
    /// A PCM window at or below this level is considered silent.
    public var silenceThresholdDBFS: Double
    public var minimumSilenceDurationMS: Int64
    /// Long media adapts the interval so visual requests never exceed this
    /// count. Requests are also decoded in bounded batches, retaining only the
    /// preceding thumbnail across batches.
    public var maximumVisualSampleCount: Int
    public var visualRequestBatchSize: Int

    public init(
        visualSampleIntervalMS: Int64 = 500,
        visualChangeThreshold: Double = 0.20,
        minimumVisualCandidateSpacingMS: Int64 = 500,
        analysisWidth: Int = 32,
        analysisHeight: Int = 18,
        audioAnalysisWindowMS: Int64 = 100,
        silenceThresholdDBFS: Double = -42,
        minimumSilenceDurationMS: Int64 = 500,
        maximumVisualSampleCount: Int = 7_200,
        visualRequestBatchSize: Int = 240
    ) {
        self.visualSampleIntervalMS = visualSampleIntervalMS
        self.visualChangeThreshold = visualChangeThreshold
        self.minimumVisualCandidateSpacingMS = minimumVisualCandidateSpacingMS
        self.analysisWidth = analysisWidth
        self.analysisHeight = analysisHeight
        self.audioAnalysisWindowMS = audioAnalysisWindowMS
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.minimumSilenceDurationMS = minimumSilenceDurationMS
        self.maximumVisualSampleCount = maximumVisualSampleCount
        self.visualRequestBatchSize = visualRequestBatchSize
    }
}

public enum TimelineFeatureExtractionError: Error, LocalizedError, Sendable {
    case missingVideoTrack
    case cannotCreateReaderOutput(String)
    case cannotStartReader(String)
    case readerFailed(String)
    case imageGenerationFailed(String)
    case cannotAnalyzeVideoFrame
    case invalidTimestamp

    public var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "媒体没有视频轨。"
        case let .cannotCreateReaderOutput(mediaType):
            "无法创建\(mediaType)时间轴读取输出。"
        case let .cannotStartReader(message):
            "无法开始读取媒体时间轴：\(message)"
        case let .readerFailed(message):
            "读取媒体时间轴失败：\(message)"
        case let .imageGenerationFailed(message):
            "生成视频分析帧失败：\(message)"
        case .cannotAnalyzeVideoFrame:
            "无法生成低分辨率视频分析帧。"
        case .invalidTimestamp:
            "媒体包含无效或不确定的时间戳。"
        }
    }
}

public enum TimelineFeatureExtractor {
    private static let audioSampleRate = 16_000.0

    /// Reads the source asset without modifying it and returns content-boundary evidence.
    /// The caller owns timeout policy; cancellation is propagated to active asset readers.
    public static func extract(
        assetURL: URL,
        configuration: TimelineFeatureExtractionConfiguration = .init()
    ) async throws -> TimelineFeatureExtractionResult {
        let configuration = normalizedConfiguration(configuration)
        let asset = AVURLAsset(url: assetURL)
        async let duration = asset.load(.duration)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)

        let (loadedDuration, loadedVideoTracks, loadedAudioTracks) = try await (
            duration,
            videoTracks,
            audioTracks
        )
        try Task.checkCancellation()
        guard !loadedVideoTracks.isEmpty else {
            throw TimelineFeatureExtractionError.missingVideoTrack
        }
        let durationMS = try signedMilliseconds(loadedDuration)
        guard durationMS >= 0 else { throw TimelineFeatureExtractionError.invalidTimestamp }

        let visual = try await extractVisualCandidates(
            asset: asset,
            durationMS: durationMS,
            configuration: configuration
        )
        try Task.checkCancellation()

        let silence: [TimelineFeatureCandidate]
        if let audioTrack = loadedAudioTracks.first {
            silence = try await extractSilenceCandidates(
                asset: asset,
                track: audioTrack,
                configuration: configuration
            )
        } else {
            silence = []
        }
        try Task.checkCancellation()

        let candidates = (visual + silence).sorted {
            if $0.timeMS != $1.timeMS { return $0.timeMS < $1.timeMS }
            return evidenceSortOrder($0.evidence) < evidenceSortOrder($1.evidence)
        }
        return TimelineFeatureExtractionResult(
            durationMS: durationMS,
            candidates: candidates
        )
    }

    private static func extractVisualCandidates(
        asset: AVAsset,
        durationMS: Int64,
        configuration: TimelineFeatureExtractionConfiguration
    ) async throws -> [TimelineFeatureCandidate] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: max(64, configuration.analysisWidth * 4),
            height: max(64, configuration.analysisHeight * 4)
        )
        let toleranceMS = min(100, max(1, configuration.visualSampleIntervalMS / 4))
        generator.requestedTimeToleranceBefore = CMTime(value: toleranceMS, timescale: 1_000)
        generator.requestedTimeToleranceAfter = CMTime(value: toleranceMS, timescale: 1_000)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let sampleIntervalMS = effectiveVisualSampleIntervalMS(
                durationMS: durationMS,
                configuration: configuration
            )
            var nextRequestTimeMS: Int64 = 0
            var previous: LuminanceThumbnail?
            var previousTimeMS: Int64?
            var candidates: [TimelineFeatureCandidate] = []

            while nextRequestTimeMS < durationMS {
                try Task.checkCancellation()
                var requestedTimes: [NSValue] = []
                requestedTimes.reserveCapacity(configuration.visualRequestBatchSize)
                while nextRequestTimeMS < durationMS,
                      requestedTimes.count < configuration.visualRequestBatchSize {
                    requestedTimes.append(
                        NSValue(time: CMTime(value: nextRequestTimeMS, timescale: 1_000))
                    )
                    let (next, overflow) = nextRequestTimeMS.addingReportingOverflow(
                        sampleIntervalMS
                    )
                    if overflow { nextRequestTimeMS = durationMS }
                    else { nextRequestTimeMS = next }
                }

                let orderedSamples = try await generateVisualBatch(
                    generator: generator,
                    requestedTimes: requestedTimes,
                    configuration: configuration
                ).sorted { $0.timeMS < $1.timeMS }

                for sample in orderedSamples {
                    let sampleTimeMS = sample.timeMS

                    // Tolerance can occasionally return the same nearby frame
                    // for two requests, and callback order is unspecified.
                    if let previousTimeMS, sampleTimeMS <= previousTimeMS { continue }

                    let thumbnail = sample.thumbnail
                    if let previous, let previousTimeMS {
                        let score = visualDifference(previous, thumbnail)
                        if score >= configuration.visualChangeThreshold {
                            let candidate = TimelineFeatureCandidate(
                                timeMS: sampleTimeMS,
                                evidence: .visualChange(
                                    score: score,
                                    previousSampleTimeMS: previousTimeMS
                                )
                            )
                            coalesceVisualCandidate(
                                candidate,
                                minimumSpacingMS: configuration.minimumVisualCandidateSpacingMS,
                                into: &candidates
                            )
                        }
                    }
                    previous = thumbnail
                    previousTimeMS = sampleTimeMS
                }
            }
            return candidates
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    private static func generateVisualBatch(
        generator: AVAssetImageGenerator,
        requestedTimes: [NSValue],
        configuration: TimelineFeatureExtractionConfiguration
    ) async throws -> [LuminanceSample] {
        let completionCounter = TimelineImageCompletionCounter(expectedCount: requestedTimes.count)
        let samples = AsyncThrowingStream<LuminanceSample, Error> { continuation in
            guard !requestedTimes.isEmpty else {
                continuation.finish()
                return
            }
            generator.generateCGImagesAsynchronously(forTimes: requestedTimes) {
                _, image, actualTime, result, error in
                switch result {
                case .succeeded:
                    guard let image else {
                        continuation.finish(
                            throwing: TimelineFeatureExtractionError.imageGenerationFailed(
                                "AVFoundation 未返回图像"
                            )
                        )
                        return
                    }
                    do {
                        continuation.yield(
                            LuminanceSample(
                                timeMS: max(0, try signedMilliseconds(actualTime)),
                                thumbnail: try luminanceThumbnail(
                                    image,
                                    width: configuration.analysisWidth,
                                    height: configuration.analysisHeight
                                )
                            )
                        )
                    } catch {
                        continuation.finish(throwing: error)
                        generator.cancelAllCGImageGeneration()
                        return
                    }
                case .failed:
                    continuation.finish(
                        throwing: TimelineFeatureExtractionError.imageGenerationFailed(
                            error?.localizedDescription ?? "未知错误"
                        )
                    )
                    generator.cancelAllCGImageGeneration()
                    return
                case .cancelled:
                    continuation.finish(throwing: CancellationError())
                    return
                @unknown default:
                    continuation.finish(
                        throwing: TimelineFeatureExtractionError.imageGenerationFailed(
                            "未知 AVFoundation 状态"
                        )
                    )
                    return
                }
                if completionCounter.completedOne() { continuation.finish() }
            }
        }

        var generated: [LuminanceSample] = []
        generated.reserveCapacity(requestedTimes.count)
        for try await sample in samples {
            try Task.checkCancellation()
            generated.append(sample)
        }
        return generated
    }

    static func effectiveVisualSampleIntervalMS(
        durationMS: Int64,
        configuration: TimelineFeatureExtractionConfiguration
    ) -> Int64 {
        guard durationMS > 0 else { return configuration.visualSampleIntervalMS }
        let limit = Int64(configuration.maximumVisualSampleCount)
        let minimumForLimit = durationMS / limit + (durationMS % limit == 0 ? 0 : 1)
        return max(configuration.visualSampleIntervalMS, minimumForLimit)
    }

    static func visualSampleCount(
        durationMS: Int64,
        configuration: TimelineFeatureExtractionConfiguration
    ) -> Int {
        guard durationMS > 0 else { return 0 }
        let interval = effectiveVisualSampleIntervalMS(
            durationMS: durationMS,
            configuration: configuration
        )
        return Int((durationMS - 1) / interval + 1)
    }

    private static func extractSilenceCandidates(
        asset: AVAsset,
        track: AVAssetTrack,
        configuration: TimelineFeatureExtractionConfiguration
    ) async throws -> [TimelineFeatureCandidate] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TimelineFeatureExtractionError.cannotCreateReaderOutput("音频")
        }
        reader.add(output)
        let cancellationHandle = TimelineReaderCancellationHandle(reader: reader)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard reader.startReading() else {
                throw TimelineFeatureExtractionError.cannotStartReader(
                    reader.error?.localizedDescription ?? "未知错误"
                )
            }

            var candidates: [TimelineFeatureCandidate] = []
            var silenceStartMS: Int64?
            var lastAudioEndMS: Int64?
            var accumulator: PCMEnergyAccumulator?

            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { break }
                let sampleRate = try decodedAudioSampleRate(sample)
                if let active = accumulator,
                   abs(active.sampleRate - sampleRate) > 0.5 {
                    if let trailing = try active.trailingWindow() {
                        consumeAudioWindow(
                            trailing,
                            configuration: configuration,
                            silenceStartMS: &silenceStartMS,
                            lastAudioEndMS: &lastAudioEndMS,
                            candidates: &candidates
                        )
                    }
                    if let start = silenceStartMS, let end = lastAudioEndMS {
                        appendSilenceCandidate(
                            startMS: start,
                            endMS: end,
                            minimumDurationMS: configuration.minimumSilenceDurationMS,
                            into: &candidates
                        )
                    }
                    silenceStartMS = nil
                    lastAudioEndMS = nil
                    accumulator = nil
                }

                if accumulator == nil {
                    accumulator = PCMEnergyAccumulator(
                        sampleRate: sampleRate,
                        windowDurationMS: configuration.audioAnalysisWindowMS
                    )
                }
                let startSampleTime = try audioSampleTime(
                    CMSampleBufferGetPresentationTimeStamp(sample),
                    sampleRate: sampleRate
                )
                let pcm = try decodedPCMSamples(sample)
                var active = accumulator!
                let batch = try active.append(pcm, at: startSampleTime)
                accumulator = active

                if let preceding = batch.precedingDiscontinuityWindow {
                    consumeAudioWindow(
                        preceding,
                        configuration: configuration,
                        silenceStartMS: &silenceStartMS,
                        lastAudioEndMS: &lastAudioEndMS,
                        candidates: &candidates
                    )
                }
                if let discontinuityEndMS = batch.discontinuityEndMS {
                    if let start = silenceStartMS {
                        appendSilenceCandidate(
                            startMS: start,
                            endMS: discontinuityEndMS,
                            minimumDurationMS: configuration.minimumSilenceDurationMS,
                            into: &candidates
                        )
                    }
                    silenceStartMS = nil
                    lastAudioEndMS = nil
                }
                for window in batch.windows {
                    consumeAudioWindow(
                        window,
                        configuration: configuration,
                        silenceStartMS: &silenceStartMS,
                        lastAudioEndMS: &lastAudioEndMS,
                        candidates: &candidates
                    )
                }
            }
            try Task.checkCancellation()
            try validateReader(reader)

            if let trailing = try accumulator?.trailingWindow() {
                consumeAudioWindow(
                    trailing,
                    configuration: configuration,
                    silenceStartMS: &silenceStartMS,
                    lastAudioEndMS: &lastAudioEndMS,
                    candidates: &candidates
                )
            }

            if let start = silenceStartMS, let end = lastAudioEndMS {
                appendSilenceCandidate(
                    startMS: start,
                    endMS: end,
                    minimumDurationMS: configuration.minimumSilenceDurationMS,
                    into: &candidates
                )
            }
            return candidates
        } onCancel: {
            cancellationHandle.cancel()
        }
    }

    /// Returns the exact bounded configuration used by `extract`. Callers that
    /// persist derivation parameters should persist this value, not unchecked input.
    public static func normalizedConfiguration(
        _ value: TimelineFeatureExtractionConfiguration
    ) -> TimelineFeatureExtractionConfiguration {
        var value = value
        value.visualSampleIntervalMS = min(60_000, max(50, value.visualSampleIntervalMS))
        value.visualChangeThreshold = value.visualChangeThreshold.isFinite
            ? min(1, max(0, value.visualChangeThreshold)) : 0.20
        value.minimumVisualCandidateSpacingMS = min(
            600_000,
            max(0, value.minimumVisualCandidateSpacingMS)
        )
        value.analysisWidth = min(256, max(2, value.analysisWidth))
        value.analysisHeight = min(256, max(2, value.analysisHeight))
        value.audioAnalysisWindowMS = min(1_000, max(10, value.audioAnalysisWindowMS))
        value.silenceThresholdDBFS = value.silenceThresholdDBFS.isFinite
            ? min(0, max(-180, value.silenceThresholdDBFS)) : -42
        value.minimumSilenceDurationMS = min(
            600_000,
            max(1, value.minimumSilenceDurationMS)
        )
        value.maximumVisualSampleCount = min(100_000, max(2, value.maximumVisualSampleCount))
        value.visualRequestBatchSize = min(
            min(1_024, value.maximumVisualSampleCount),
            max(1, value.visualRequestBatchSize)
        )
        return value
    }

    private static func evidenceSortOrder(_ evidence: TimelineFeatureCandidate.Evidence) -> Int {
        switch evidence {
        case .visualChange: 0
        case .silenceEnd: 1
        }
    }

    private static func coalesceVisualCandidate(
        _ candidate: TimelineFeatureCandidate,
        minimumSpacingMS: Int64,
        into candidates: inout [TimelineFeatureCandidate]
    ) {
        guard let previous = candidates.last,
              candidate.timeMS - previous.timeMS < minimumSpacingMS
        else {
            candidates.append(candidate)
            return
        }
        guard case let .visualChange(newScore, _) = candidate.evidence,
              case let .visualChange(previousScore, _) = previous.evidence,
              newScore > previousScore
        else { return }
        candidates[candidates.count - 1] = candidate
    }

    private static func appendSilenceCandidate(
        startMS: Int64,
        endMS: Int64,
        minimumDurationMS: Int64,
        into candidates: inout [TimelineFeatureCandidate]
    ) {
        let durationMS = max(0, endMS - startMS)
        guard durationMS >= minimumDurationMS else { return }
        candidates.append(
            TimelineFeatureCandidate(
                timeMS: endMS,
                evidence: .silenceEnd(startTimeMS: startMS, durationMS: durationMS)
            )
        )
    }

    private struct LuminanceThumbnail: Sendable {
        let pixels: [UInt8]
        let histogram: [Double]
    }

    private struct LuminanceSample: Sendable {
        let timeMS: Int64
        let thumbnail: LuminanceThumbnail
    }

    private static func luminanceThumbnail(
        _ image: CGImage,
        width: Int,
        height: Int
    ) throws -> LuminanceThumbnail {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            throw TimelineFeatureExtractionError.cannotAnalyzeVideoFrame
        }

        var histogram = [Double](repeating: 0, count: 16)
        for luminance in pixels {
            histogram[Int(luminance) >> 4] += 1
        }
        let count = Double(pixels.count)
        histogram = histogram.map { $0 / count }
        return LuminanceThumbnail(pixels: pixels, histogram: histogram)
    }

    private static func visualDifference(
        _ lhs: LuminanceThumbnail,
        _ rhs: LuminanceThumbnail
    ) -> Double {
        let pixelDistance = zip(lhs.pixels, rhs.pixels).reduce(0.0) {
            $0 + abs(Double($1.0) - Double($1.1)) / 255
        } / Double(lhs.pixels.count)
        let histogramDistance = zip(lhs.histogram, rhs.histogram).reduce(0.0) {
            $0 + abs($1.0 - $1.1)
        } / 2
        return min(1, pixelDistance * 0.65 + histogramDistance * 0.35)
    }

    struct AudioEnergyWindow: Equatable {
        let startMS: Int64
        let endMS: Int64
        let levelDBFS: Double
    }

    struct AudioAccumulatorBatch {
        let precedingDiscontinuityWindow: AudioEnergyWindow?
        let discontinuityEndMS: Int64?
        let windows: [AudioEnergyWindow]
    }

    struct PCMEnergyAccumulator {
        let sampleRate: Double
        private let windowSampleCount: Int
        private var pending: [Int16] = []
        private var pendingStartSampleTime: Int64?
        private var expectedNextSampleTime: Int64?

        init(sampleRate: Double, windowDurationMS: Int64) {
            self.sampleRate = sampleRate
            windowSampleCount = max(
                1,
                Int((sampleRate * Double(windowDurationMS) / 1_000).rounded())
            )
        }

        mutating func append(
            _ samples: [Int16],
            at startSampleTime: Int64
        ) throws -> AudioAccumulatorBatch {
            var precedingWindow: AudioEnergyWindow?
            var discontinuityEndMS: Int64?
            if let expectedNextSampleTime {
                let (difference, overflow) = startSampleTime.subtractingReportingOverflow(
                    expectedNextSampleTime
                )
                guard !overflow, difference != Int64.min else {
                    throw TimelineFeatureExtractionError.invalidTimestamp
                }
                if abs(difference) > 2 {
                    precedingWindow = try trailingWindow()
                    discontinuityEndMS = try milliseconds(expectedNextSampleTime)
                    pending.removeAll(keepingCapacity: true)
                    pendingStartSampleTime = nil
                }
            }

            if pendingStartSampleTime == nil { pendingStartSampleTime = startSampleTime }
            pending.append(contentsOf: samples)
            let (nextExpectedTime, expectedOverflow) = startSampleTime.addingReportingOverflow(
                Int64(samples.count)
            )
            guard !expectedOverflow else {
                throw TimelineFeatureExtractionError.invalidTimestamp
            }
            expectedNextSampleTime = nextExpectedTime

            var windows: [AudioEnergyWindow] = []
            while pending.count >= windowSampleCount,
                  let windowStart = pendingStartSampleTime {
                let windowSamples = pending.prefix(windowSampleCount)
                windows.append(try makeWindow(windowSamples, startSampleTime: windowStart))
                pending.removeFirst(windowSampleCount)
                let (nextWindowStart, windowOverflow) = windowStart.addingReportingOverflow(
                    Int64(windowSampleCount)
                )
                guard !windowOverflow else {
                    throw TimelineFeatureExtractionError.invalidTimestamp
                }
                pendingStartSampleTime = nextWindowStart
            }
            return AudioAccumulatorBatch(
                precedingDiscontinuityWindow: precedingWindow,
                discontinuityEndMS: discontinuityEndMS,
                windows: windows
            )
        }

        func trailingWindow() throws -> AudioEnergyWindow? {
            guard !pending.isEmpty, let start = pendingStartSampleTime else { return nil }
            return try makeWindow(pending[...], startSampleTime: start)
        }

        private func makeWindow<C: Collection>(
            _ samples: C,
            startSampleTime: Int64
        ) throws -> AudioEnergyWindow where C.Element == Int16 {
            var sumSquares = 0.0
            for sample in samples {
                let normalized = Double(sample) / Double(Int16.max)
                sumSquares += normalized * normalized
            }
            let rms = sqrt(sumSquares / Double(samples.count))
            let (endSampleTime, overflow) = startSampleTime.addingReportingOverflow(
                Int64(samples.count)
            )
            guard !overflow else { throw TimelineFeatureExtractionError.invalidTimestamp }
            return AudioEnergyWindow(
                startMS: try milliseconds(startSampleTime),
                endMS: try milliseconds(endSampleTime),
                levelDBFS: 20 * log10(max(rms, 1e-9))
            )
        }

        private func milliseconds(_ sampleTime: Int64) throws -> Int64 {
            let value = (Double(sampleTime) / sampleRate * 1_000).rounded()
            guard value.isFinite,
                  value >= Double(Int64.min),
                  value < Double(Int64.max) else {
                throw TimelineFeatureExtractionError.invalidTimestamp
            }
            return Int64(value)
        }
    }

    private static func decodedPCMSamples(_ sample: CMSampleBuffer) throws -> [Int16] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount >= MemoryLayout<Int16>.size else { return [] }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw TimelineFeatureExtractionError.readerFailed("无法读取 PCM 样本（\(status)）")
        }

        let sampleCount = min(
            CMSampleBufferGetNumSamples(sample),
            bytes.count / MemoryLayout<Int16>.size
        )
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let offset = index * 2
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Int16(bitPattern: bits))
        }
        return samples
    }

    private static func decodedAudioSampleRate(_ sample: CMSampleBuffer) throws -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else {
            throw TimelineFeatureExtractionError.readerFailed("PCM 样本缺少音频格式")
        }
        let sampleRate = description.pointee.mSampleRate
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 384_000 else {
            throw TimelineFeatureExtractionError.readerFailed("PCM 采样率无效")
        }
        return sampleRate
    }

    private static func audioSampleTime(_ time: CMTime, sampleRate: Double) throws -> Int64 {
        guard time.isValid, !time.isIndefinite else {
            throw TimelineFeatureExtractionError.invalidTimestamp
        }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { throw TimelineFeatureExtractionError.invalidTimestamp }
        let sampleTime = (seconds * sampleRate).rounded()
        guard sampleTime >= Double(Int64.min), sampleTime < Double(Int64.max) else {
            throw TimelineFeatureExtractionError.invalidTimestamp
        }
        return Int64(sampleTime)
    }

    private static func consumeAudioWindow(
        _ window: AudioEnergyWindow,
        configuration: TimelineFeatureExtractionConfiguration,
        silenceStartMS: inout Int64?,
        lastAudioEndMS: inout Int64?,
        candidates: inout [TimelineFeatureCandidate]
    ) {
        let startMS = max(0, window.startMS)
        let endMS = max(0, window.endMS)
        lastAudioEndMS = endMS
        if window.levelDBFS <= configuration.silenceThresholdDBFS {
            if silenceStartMS == nil { silenceStartMS = startMS }
        } else if let start = silenceStartMS {
            appendSilenceCandidate(
                startMS: start,
                endMS: startMS,
                minimumDurationMS: configuration.minimumSilenceDurationMS,
                into: &candidates
            )
            silenceStartMS = nil
        }
    }

    private static func validateReader(_ reader: AVAssetReader) throws {
        if reader.status == .failed {
            throw TimelineFeatureExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "未知错误"
            )
        }
        if reader.status == .cancelled {
            throw CancellationError()
        }
    }

    private static func signedMilliseconds(_ time: CMTime) throws -> Int64 {
        guard time.isValid, !time.isIndefinite else {
            throw TimelineFeatureExtractionError.invalidTimestamp
        }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { throw TimelineFeatureExtractionError.invalidTimestamp }
        let milliseconds = (seconds * 1_000).rounded()
        guard milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
            throw TimelineFeatureExtractionError.invalidTimestamp
        }
        return Int64(milliseconds)
    }
}

private final class TimelineReaderCancellationHandle: @unchecked Sendable {
    private let reader: AVAssetReader

    init(reader: AVAssetReader) {
        self.reader = reader
    }

    func cancel() {
        reader.cancelReading()
    }
}

private final class TimelineImageCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedCount: Int
    private var completedCount = 0

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func completedOne() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        completedCount += 1
        return completedCount == expectedCount
    }
}
