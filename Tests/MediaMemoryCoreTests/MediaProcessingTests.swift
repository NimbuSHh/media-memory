import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaMemoryCore
import XCTest

final class MediaProcessingTests: XCTestCase {
    func testAudioAndFramesUseSourceTimeWithoutChangingVideo() async throws {
        let video = try testVideoURL()
        let before = try FileFingerprint.snapshot(for: video)
        let temporary = try ProcessingTemporaryDirectory()
        let audio = temporary.url.appending(path: "sample.wav")
        let framesDirectory = temporary.url.appending(path: "frames", directoryHint: .isDirectory)

        _ = try await AudioSegmentExtractor.extractWAV(
            assetURL: video,
            startMS: 0,
            endMS: 6_000,
            destinationURL: audio
        )
        let frames = try await FrameExtractor.extract(
            assetURL: video,
            startMS: 0,
            endMS: 6_000,
            destinationDirectory: framesDirectory
        )
        let after = try FileFingerprint.snapshot(for: video)

        XCTAssertEqual(after, before)
        XCTAssertGreaterThan(try Data(contentsOf: audio).count, 44)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { (0..<6_000).contains($0.timeMS) })
        XCTAssertLessThanOrEqual(FrameExtractor.representatives(from: frames).count, 8)
        _ = try VisionTextRecognizer.recognize(frames: frames)
    }

    func testSentenceAggregationProducesSentenceRanges() {
        let tokens = [
            AlignedToken(text: "你好", startMS: 100, endMS: 500),
            AlignedToken(text: "。", startMS: 500, endMS: 600),
            AlignedToken(text: "出发", startMS: 900, endMS: 1_300),
            AlignedToken(text: "！", startMS: 1_300, endMS: 1_400)
        ]

        let sentences = SentenceTiming.aggregate(
            transcript: "你好。出发！",
            language: "Chinese",
            tokens: tokens,
            blockStartMS: 20_000,
            blockEndMS: 40_000
        )

        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].text, "你好。")
        XCTAssertEqual(sentences[0].startMS, 20_100)
        XCTAssertEqual(sentences[0].endMS, 20_600)
        XCTAssertEqual(sentences[1].startMS, 20_900)
        XCTAssertEqual(sentences[1].endMS, 21_400)
    }

    func testPersistentThumbnailIsDecodableAndNeverExceedsFourKiB() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let source = temporary.url.appending(path: "source.jpg")
        try writeSyntheticJPEG(to: source)
        let thumbnail = temporary.url.appending(path: "thumbnail.jpg")
        try FrameExtractor.writePersistentThumbnail(from: source, to: thumbnail)

        let size = try XCTUnwrap(
            thumbnail.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertLessThanOrEqual(size, FrameExtractor.persistentThumbnailMaximumBytes)
        XCTAssertNotNil(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))

        let legacy = temporary.url.appending(path: "legacy.jpg")
        try FileManager.default.copyItem(at: source, to: legacy)
        try FrameExtractor.compactPersistentThumbnail(at: legacy)
        let compactedSize = try XCTUnwrap(
            legacy.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertLessThanOrEqual(
            compactedSize,
            FrameExtractor.persistentThumbnailMaximumBytes
        )
        XCTAssertNotNil(CGImageSourceCreateWithURL(legacy as CFURL, nil))

        let migrationRoot = temporary.url.appending(path: "migration")
        let goodRelativePath = "Frames/good.jpg"
        let badRelativePath = "Frames/bad.jpg"
        let good = migrationRoot.appending(path: goodRelativePath)
        let bad = migrationRoot.appending(path: badRelativePath)
        try FileManager.default.createDirectory(
            at: good.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: good)
        try Data("not-an-image".utf8).write(to: bad)
        try ApplicationPaths.compactReferencedFrames(
            in: migrationRoot,
            referencedRelativePaths: [goodRelativePath, badRelativePath]
        )
        let migratedSize = try XCTUnwrap(
            good.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertLessThanOrEqual(
            migratedSize,
            FrameExtractor.persistentThumbnailMaximumBytes
        )
        XCTAssertEqual(try Data(contentsOf: bad), Data("not-an-image".utf8))
    }

    func testLocalSourceCacheKeepsOnlyOneVerifiedVideoAndRemovesIt() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let sourceA = temporary.url.appending(path: "a.bin")
        let sourceB = temporary.url.appending(path: "b.bin")
        try Data(repeating: 0x41, count: 8 * 1_024 * 1_024).write(to: sourceA)
        try Data(repeating: 0x42, count: 48 * 1_024).write(to: sourceB)
        let assetA = try assetRecord(id: "asset-a", source: sourceA)
        let assetB = try assetRecord(id: "asset-b", source: sourceB)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )

        async let firstLoad = cache.localURL(for: assetA)
        async let secondLoad = cache.localURL(for: assetA)
        let (firstA, secondA) = try await (firstLoad, secondLoad)
        XCTAssertEqual(firstA, secondA)
        XCTAssertEqual(try Data(contentsOf: firstA), try Data(contentsOf: sourceA))

        let cachedB = try await cache.localURL(for: assetB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstA.path))
        XCTAssertEqual(try Data(contentsOf: cachedB), try Data(contentsOf: sourceB))
        let cachedAssetID = await cache.cachedAssetID()
        XCTAssertEqual(cachedAssetID, assetB.id)

        try await cache.remove(assetID: assetB.id)
        let removedAssetID = await cache.cachedAssetID()
        XCTAssertNil(removedAssetID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedB.path))
    }

    func testLocalSourceAuthorizationIsLazyAndOnlyRunsWhenMaterializing() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let source = temporary.url.appending(path: "authorized.bin")
        try Data(repeating: 0x61, count: 32 * 1_024).write(to: source)
        let asset = try assetRecord(id: "authorized", source: source)
        let recorder = SourceAuthorizationRecorder()
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max },
            authorizeSource: { asset in await recorder.record(asset.id) }
        )

        let beforeMaterialization = await recorder.assetIDs()
        XCTAssertEqual(beforeMaterialization, [])
        let first = try await cache.localURL(for: asset)
        let afterFirstMaterialization = await recorder.assetIDs()
        XCTAssertEqual(afterFirstMaterialization, [asset.id])
        let second = try await cache.localURL(for: asset)
        XCTAssertEqual(first, second)
        let afterCachedReuse = await recorder.assetIDs()
        XCTAssertEqual(afterCachedReuse, [asset.id])
    }

    func testLocalSourceCacheRefusesCopyWhenReserveWouldBeConsumed() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let source = temporary.url.appending(path: "large.bin")
        try Data(repeating: 0x7F, count: 8 * 1_024).write(to: source)
        let asset = try assetRecord(id: "asset", source: source)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 4 * 1_024,
            availableCapacity: { _ in 10 * 1_024 }
        )

        do {
            _ = try await cache.localURL(for: asset)
            XCTFail("空间不足时不应开始缓存")
        } catch LocalSourceCacheError.insufficientSpace {
            // expected
        }
        let cachedAssetID = await cache.cachedAssetID()
        XCTAssertNil(cachedAssetID)
    }

    func testLocalSourceCacheRejectsASingleOversizedVideo() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let source = temporary.url.appending(path: "oversized.bin")
        try Data(repeating: 0x55, count: 8 * 1_024).write(to: source)
        let asset = try assetRecord(id: "oversized", source: source)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            maximumSourceBytes: 4 * 1_024,
            availableCapacity: { _ in 1_024 * 1_024 }
        )

        do {
            _ = try await cache.localURL(for: asset)
            XCTFail("单个视频超过缓存上限时不应开始复制")
        } catch LocalSourceCacheError.sourceTooLarge {
            // expected
        }
        let cachedAssetID = await cache.cachedAssetID()
        XCTAssertNil(cachedAssetID)
    }

    func testLocalSourceCacheRemovalWaitsForActualReaderToFinish() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let source = temporary.url.appending(path: "leased.bin")
        try Data(repeating: 0x33, count: 128 * 1_024).write(to: source)
        let asset = try assetRecord(id: "leased", source: source)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        let control = SourceLeaseTestControl()
        let reader = Task {
            try await cache.withLocalURL(for: asset) { url in
                await control.hold()
                return url
            }
        }
        await control.waitUntilStarted()
        let cachedURL = try await cache.localURL(for: asset)
        let removal = Task {
            try await cache.removeIfUnused(assetID: asset.id) { false }
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedURL.path))

        await control.finish()
        _ = try await reader.value
        let removedAfterRecheck = try await removal.value
        XCTAssertFalse(removedAfterRecheck)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedURL.path))

        try await cache.remove(assetID: asset.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
    }

    func testUnusedCheckDoesNotDeadlockNestedSourceLease() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let source = temporary.url.appending(path: "nested.bin")
        try Data(repeating: 0x22, count: 128 * 1_024).write(to: source)
        let asset = try assetRecord(id: "nested", source: source)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        let control = SourceLeaseTestControl()
        let nestedReader = Task {
            try await cache.withLocalURL(for: asset) { _ in
                await control.hold()
                return try await cache.withLocalURL(for: asset) { $0 }
            }
        }
        await control.waitUntilStarted()

        let removed = try await AsyncTimeout.run(
            for: .seconds(1),
            operationName: "检查缓存是否仍在使用"
        ) {
            try await cache.removeIfUnused(assetID: asset.id) { false }
        }
        XCTAssertFalse(removed)

        await control.finish()
        _ = try await nestedReader.value
        try await cache.remove(assetID: asset.id)
    }

    func testActiveLeasePreventsAnotherVideoFromReplacingCache() async throws {
        let temporary = try ProcessingTemporaryDirectory()
        let sourceA = temporary.url.appending(path: "leased-a.bin")
        let sourceB = temporary.url.appending(path: "waiting-b.bin")
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: sourceA)
        try Data(repeating: 0x42, count: 128 * 1_024).write(to: sourceB)
        let assetA = try assetRecord(id: "leased-a", source: sourceA)
        let assetB = try assetRecord(id: "waiting-b", source: sourceB)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        let control = SourceLeaseTestControl()
        let reader = Task {
            try await cache.withLocalURL(for: assetA) { url in
                await control.hold()
                return url
            }
        }
        await control.waitUntilStarted()

        let cachedA = try await cache.localURL(for: assetA)
        XCTAssertEqual(try Data(contentsOf: cachedA), try Data(contentsOf: sourceA))
        do {
            _ = try await cache.localURL(for: assetB)
            XCTFail("有读取者时不应切换到另一视频")
        } catch LocalSourceCacheError.cacheInUse {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedA.path))
        XCTAssertEqual(try Data(contentsOf: cachedA), try Data(contentsOf: sourceA))

        await control.finish()
        _ = try await reader.value
        let cachedB = try await cache.localURL(for: assetB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedA.path))
        XCTAssertEqual(try Data(contentsOf: cachedB), try Data(contentsOf: sourceB))
    }

    private func testVideoURL() throws -> URL {
        try TestMediaFixture.videoURL()
    }

    private func assetRecord(id: String, source: URL) throws -> MediaAssetRecord {
        let snapshot = try FileFingerprint.snapshot(for: source)
        return MediaAssetRecord(
            id: id,
            rootID: "root",
            relativePath: source.lastPathComponent,
            standardizedPath: source.path,
            fileSize: snapshot.fileSize,
            modificationDate: snapshot.modificationDate,
            durationMS: 1_000,
            videoTrackCount: 1,
            audioTrackCount: 1,
            isPlayable: true,
            fingerprint: try FileFingerprint.lightFingerprint(for: source, snapshot: snapshot),
            status: .ready,
            errorMessage: nil,
            firstSeenAt: Date(),
            lastSeenAt: Date()
        )
    }

    private func writeSyntheticJPEG(to url: URL) throws {
        let width = 640
        let height = 360
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = UInt8(truncatingIfNeeded: index &* 31)
            pixels[index * 4 + 1] = UInt8(truncatingIfNeeded: index &* 17)
            pixels[index * 4 + 2] = UInt8(truncatingIfNeeded: index &* 7)
            pixels[index * 4 + 3] = 255
        }
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else {
                throw FrameExtractionError.cannotWriteImage(url.path)
            }
            return image
        }
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
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw FrameExtractionError.cannotWriteImage(url.path)
        }
    }
}

private final class ProcessingTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-processing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor SourceLeaseTestControl {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor SourceAuthorizationRecorder {
    private var recordedAssetIDs: [String] = []

    func record(_ assetID: String) {
        recordedAssetIDs.append(assetID)
    }

    func assetIDs() -> [String] {
        recordedAssetIDs
    }
}
