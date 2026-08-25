@preconcurrency import AVFoundation
import Foundation

public enum AudioExtractionError: Error, LocalizedError, Sendable {
    case missingAudioTrack
    case cannotCreateReaderOutput
    case cannotStart(String)
    case appendFailed(String)
    case finishFailed(String)
    case emptyAudio(String)

    public var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            "视频没有音轨。"
        case .cannotCreateReaderOutput:
            "无法创建音频读取输出。"
        case let .cannotStart(message):
            "无法开始提取音频：\(message)"
        case let .appendFailed(message):
            "写入音频片段失败：\(message)"
        case let .finishFailed(message):
            "完成音频片段失败：\(message)"
        case let .emptyAudio(message):
            "该片段音轨没有可解码的音频数据（\(message)），无法做语音识别。"
        }
    }
}

/// 直接从源视频的指定时间范围解码出 16 kHz 单声道 16 位 PCM WAV。
/// 使用强制解码设置（非 passthrough），单次读取单次写出，不经过
/// 中间容器与 afconvert——任何解码失败都会带着明确原因抛出，
/// 不会静默产出无法解析的音频文件。
public enum AudioSegmentExtractor {
    private static func pcmSettings() -> [String: Any] {[
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]}

    public static func extractWAV(
        assetURL: URL,
        startMS: Int64,
        endMS: Int64,
        destinationURL: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let asset = AVURLAsset(url: assetURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioExtractionError.missingAudioTrack
        }

        let timeRange = CMTimeRange(
            start: CMTime(value: startMS, timescale: 1_000),
            duration: CMTime(value: endMS - startMS, timescale: 1_000)
        )
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings())
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioExtractionError.cannotCreateReaderOutput
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings())
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioExtractionError.cannotStart("无法创建 WAV 写入输入")
        }
        writer.add(writerInput)
        let cancellationHandle = AudioExtractionCancellationHandle(reader: reader, writer: writer)

        return try await withTaskCancellationHandler {
            do {
                guard writer.startWriting(), reader.startReading() else {
                    throw AudioExtractionError.cannotStart(
                        writer.error?.localizedDescription
                            ?? reader.error?.localizedDescription
                            ?? "未知错误"
                    )
                }
                writer.startSession(atSourceTime: timeRange.start)

                var sampleCount = 0
                while reader.status == .reading {
                    try Task.checkCancellation()
                    if !writerInput.isReadyForMoreMediaData {
                        try await Task.sleep(for: .milliseconds(2))
                        continue
                    }
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        break
                    }
                    guard writerInput.append(sample) else {
                        throw AudioExtractionError.appendFailed(
                            writer.error?.localizedDescription ?? "未知错误"
                        )
                    }
                    sampleCount += 1
                }
                try Task.checkCancellation()
                if reader.status == .failed {
                    throw AudioExtractionError.appendFailed(
                        reader.error?.localizedDescription ?? "未知错误"
                    )
                }
                guard sampleCount > 0 else {
                    throw AudioExtractionError.emptyAudio(assetURL.lastPathComponent)
                }
                writerInput.markAsFinished()
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else {
                    throw AudioExtractionError.finishFailed(
                        writer.error?.localizedDescription ?? "未知错误"
                    )
                }
                return destinationURL
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        } onCancel: {
            cancellationHandle.cancel()
        }
    }
}

/// AVAssetReader/Writer cancellation is documented as callable while work is in
/// progress, but the Objective-C classes are not annotated Sendable.
private final class AudioExtractionCancellationHandle: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter

    init(reader: AVAssetReader, writer: AVAssetWriter) {
        self.reader = reader
        self.writer = writer
    }

    func cancel() {
        reader.cancelReading()
        writer.cancelWriting()
    }
}
