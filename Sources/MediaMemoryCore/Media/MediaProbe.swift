@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

struct MediaProbeResult: Equatable, Sendable {
    let durationMS: Int64
    let videoTrackCount: Int
    let audioTrackCount: Int
    let isPlayable: Bool
    let mediaKind: MediaKind
    let pixelWidth: Int
    let pixelHeight: Int
}

enum MediaProbe {
    static func inspect(url: URL) async throws -> MediaProbeResult {
        try await AsyncTimeout.run(for: .seconds(30), operationName: "读取媒体信息") {
            let kind = MediaKind(forExtension: url.pathExtension) ?? .video
            switch kind {
            case .video:
                return try await inspectVideo(url: url)
            case .image:
                return try inspectImage(url: url)
            }
        }
    }

    private static func inspectVideo(url: URL) async throws -> MediaProbeResult {
        let asset = AVURLAsset(url: url)
        async let duration = asset.load(.duration)
        async let isPlayable = asset.load(.isPlayable)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)

        let loadedDuration = try await duration
        let seconds = CMTimeGetSeconds(loadedDuration)
        guard seconds.isFinite, seconds > 0 else {
            throw MediaScanError.invalidDuration(url.path)
        }

        let loadedVideoTracks = try await videoTracks
        guard !loadedVideoTracks.isEmpty else {
            throw MediaScanError.missingVideoTrack(url.path)
        }

        return try await MediaProbeResult(
            durationMS: Int64((seconds * 1_000).rounded()),
            videoTrackCount: loadedVideoTracks.count,
            audioTrackCount: audioTracks.count,
            isPlayable: isPlayable,
            mediaKind: .video,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    /// 图片探测：只读元数据与解码器状态，不做完整解码。可解码即就绪；
    /// 时长取名义值，轨道计数保持 0（图片没有 AVFoundation 意义上的轨道）。
    private static func inspectImage(url: URL) throws -> MediaProbeResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaScanError.undecodableImage(url.path)
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw MediaScanError.undecodableImage(url.path)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw MediaScanError.undecodableImage(url.path)
        }
        return MediaProbeResult(
            durationMS: MediaKind.image.nominalDurationMS ?? 0,
            videoTrackCount: 0,
            audioTrackCount: 0,
            isPlayable: true,
            mediaKind: .image,
            pixelWidth: width,
            pixelHeight: height
        )
    }
}
