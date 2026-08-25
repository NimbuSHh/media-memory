@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct FrameSample: Equatable, Sendable {
    public let timeMS: Int64
    public let imageURL: URL
    public let perceptualHash: UInt64
}

public enum FrameExtractionError: Error, LocalizedError, Sendable {
    case cannotWriteImage(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotWriteImage(path):
            "无法写入抽样帧：\(path)"
        }
    }
}

public enum FrameExtractor {
    public static func extract(
        assetURL: URL,
        startMS: Int64,
        endMS: Int64,
        destinationDirectory: URL
    ) async throws -> [FrameSample] {
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let asset = AVURLAsset(url: assetURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 1_280)
        generator.requestedTimeToleranceBefore = CMTime(value: 100, timescale: 1_000)
        generator.requestedTimeToleranceAfter = CMTime(value: 100, timescale: 1_000)

        var requestedTimes: [Int64] = []
        var time = startMS + min(500, max(0, (endMS - startMS) / 2))
        while time < endMS {
            requestedTimes.append(time)
            time += 1_000
        }
        if requestedTimes.isEmpty {
            requestedTimes = [(startMS + endMS) / 2]
        }

        return try await withTaskCancellationHandler {
            var frames: [FrameSample] = []
            var lastHash: UInt64?
            for requestedMS in requestedTimes {
                try Task.checkCancellation()
                let requested = CMTime(value: requestedMS, timescale: 1_000)
                let (image, actualTime) = try await generator.image(at: requested)
                try Task.checkCancellation()
                let actualMS = max(startMS, min(endMS - 1, milliseconds(actualTime)))
                let hash = perceptualHash(image)
                if let lastHash, (lastHash ^ hash).nonzeroBitCount <= 4 {
                    continue
                }
                let filename = String(format: "%012lld.jpg", actualMS)
                let imageURL = destinationDirectory.appending(path: filename)
                try writeJPEG(image, to: imageURL)
                frames.append(FrameSample(timeMS: actualMS, imageURL: imageURL, perceptualHash: hash))
                lastHash = hash
            }
            return frames
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    public static func representatives(from frames: [FrameSample], limit: Int = 8) -> [FrameSample] {
        guard frames.count > limit, limit > 1 else {
            return Array(frames.prefix(max(0, limit)))
        }
        return (0..<limit).map { index in
            let position = Int(
                (Double(index) * Double(frames.count - 1) / Double(limit - 1)).rounded()
            )
            return frames[position]
        }
    }

    private static func milliseconds(_ time: CMTime) -> Int64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000).rounded())
    }

    private static func perceptualHash(_ image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: 64)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return pixels.enumerated().reduce(UInt64(0)) { result, item in
            item.element >= average ? result | (UInt64(1) << UInt64(item.offset)) : result
        }
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FrameExtractionError.cannotWriteImage(url.path)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw FrameExtractionError.cannotWriteImage(url.path)
        }
    }
}
