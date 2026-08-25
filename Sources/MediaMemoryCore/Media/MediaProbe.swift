@preconcurrency import AVFoundation
import Foundation

struct MediaProbeResult: Equatable, Sendable {
    let durationMS: Int64
    let videoTrackCount: Int
    let audioTrackCount: Int
    let isPlayable: Bool
}

enum MediaProbe {
    static func inspect(url: URL) async throws -> MediaProbeResult {
        try await AsyncTimeout.run(for: .seconds(30), operationName: "读取媒体信息") {
            try await inspectWithoutTimeout(url: url)
        }
    }

    private static func inspectWithoutTimeout(url: URL) async throws -> MediaProbeResult {
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
            isPlayable: isPlayable
        )
    }
}
