import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import MediaMemoryCore
import XCTest

/// 图片支持的全链路验证：探测 → 入库 → 单段语义分片 → 建库配方隔离 →
/// 向量装载。图片使用运行时生成的 PNG fixture，不依赖二进制测试资源。
final class ImagePipelineTests: XCTestCase {
    // MARK: Fixtures

    /// 测试专用的临时目录：deinit 兜底清理。
    private final class TestDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "media-memory-image-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 生成一张确定的纯色 PNG，返回 (文件, 像素宽, 像素高)。
    @discardableResult
    private func writePNG(
        to url: URL,
        width: Int = 64,
        height: Int = 48
    ) throws -> URL {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try XCTUnwrap(context?.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeImageDirectory() throws -> (directory: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-image-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    private func sampleImageAsset(
        relativePath: String,
        fingerprint: String = "fp-image",
        pixelWidth: Int = 64,
        pixelHeight: Int = 48
    ) -> ScannedMediaAsset {
        ScannedMediaAsset(
            relativePath: relativePath,
            standardizedPath: "/" + relativePath,
            fileIdentifier: nil,
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 100),
            durationMS: MediaKind.image.nominalDurationMS ?? 0,
            videoTrackCount: 0,
            audioTrackCount: 0,
            isPlayable: true,
            fingerprint: fingerprint,
            status: .ready,
            errorMessage: nil,
            mediaKind: .image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    // MARK: 探测与扫描

    func testMediaKindDispatchAndNominalDuration() {
        XCTAssertEqual(MediaKind(forExtension: "PNG"), .image)
        XCTAssertEqual(MediaKind(forExtension: "heic"), .image)
        XCTAssertEqual(MediaKind(forExtension: "mov"), .video)
        XCTAssertNil(MediaKind(forExtension: "gif"))
        XCTAssertEqual(MediaKind.image.nominalDurationMS, 1_000)
        XCTAssertNil(MediaKind.video.nominalDurationMS)
        XCTAssertTrue(MediaScanner.supportedExtensions.contains("png"))
        XCTAssertTrue(MediaScanner.supportedExtensions.contains("mp4"))
    }

    func testScanProbesImageWithNominalTimelineAndDimensions() async throws {
        let (directory, cleanup) = try makeImageDirectory()
        defer { cleanup() }
        try writePNG(to: directory.appending(path: "picture.png"), width: 320, height: 240)

        let result = try await MediaScanner().scan(rootURL: directory)
        XCTAssertTrue(result.isAuthoritativeComplete, "\(result.errors)")
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.mediaKind, .image)
        XCTAssertEqual(asset.status, .ready)
        XCTAssertEqual(asset.durationMS, MediaKind.image.nominalDurationMS)
        XCTAssertEqual(asset.videoTrackCount, 0)
        XCTAssertEqual(asset.audioTrackCount, 0)
        XCTAssertEqual(asset.pixelWidth, 320)
        XCTAssertEqual(asset.pixelHeight, 240)
    }

    func testScanRejectsCorruptImageWithoutProducingAsset() async throws {
        let (directory, cleanup) = try makeImageDirectory()
        defer { cleanup() }
        try Data("这不是图片内容".utf8).write(to: directory.appending(path: "broken.png"))

        let result = try await MediaScanner().scan(rootURL: directory)
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(result.isAuthoritativeComplete)
    }

    // MARK: 入库与分片

    func testImageAssetRoundTripKeepsKindAndNominalCoverage() async throws {
        let temporary = try TestDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleImageAsset(relativePath: "photo.jpg")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )

        let assets = try await database.mediaAssets()
        let asset = try XCTUnwrap(assets.first)
        XCTAssertEqual(asset.mediaKind, .image)
        XCTAssertEqual(asset.pixelWidth, 64)
        XCTAssertEqual(asset.pixelHeight, 48)
        XCTAssertFalse(asset.hasTimeline)
        XCTAssertEqual(asset.durationMS, 1_000)

        // 图片不创建扫描期兼容段；语义分片任务正常入队。
        try await database.reconcileSegmentationJobs(
            algorithmVersionByKind: [
                MediaKind.video: "video-algo-1",
                MediaKind.image: "static-single-v1-image"
            ]
        )
        let segmentsBeforeCommit = try await database.segments(assetID: asset.id)
        XCTAssertTrue(segmentsBeforeCommit.isEmpty)
        let target = try await database.claimNextSegmentationJob()
        guard case let .target(segmentationTarget) = target else {
            return XCTFail("图片资产应有 segment_asset 任务")
        }
        XCTAssertEqual(segmentationTarget.asset.mediaKind, .image)

        // 名义段 [0, 1000) 恰好覆盖名义时长，通过覆盖校验原子提交。
        try await database.commitSegmentation(
            claim: segmentationTarget.job.claimToken,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            algorithmVersion: "static-single-v1-image",
            parametersJSON: "{\"algorithm_version\":\"static-single-v1-image\"}",
            segments: [SemanticSegmentDraft(startMS: 0, endMS: 1_000)]
        )
        let committed = try await database.segments(assetID: asset.id)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.startMS, 0)
        XCTAssertEqual(committed.first?.endMS, 1_000)

        // 算法身份稳定：再次 reconcile 不得给图片资产重复入队。
        try await database.reconcileSegmentationJobs(
            algorithmVersionByKind: [
                MediaKind.video: "video-algo-1",
                MediaKind.image: "static-single-v1-image"
            ]
        )
        let idle = try await database.claimNextSegmentationJob()
        guard case .idle = idle else {
            return XCTFail("算法身份未变化时不应再次入队")
        }
    }

    // MARK: 建库配方隔离

    func testImageAndVideoInputVersionsAreIndependent() {
        let configuration = testConfiguration()

        let videoVersion = SegmentIndexer.inputVersion(for: configuration, kind: .video)
        let imageVersion = SegmentIndexer.inputVersion(for: configuration, kind: .image)
        XCTAssertNotEqual(videoVersion, imageVersion)

        // 黄金约束：视频配方与历史字节逐位一致。任何变化都会触发全库
        // 重新嵌入，必须是有意识的发布决定。
        XCTAssertEqual(
            videoVersion,
            SegmentIndexer.inputVersion(for: configuration)
        )
        XCTAssertEqual(
            videoVersion,
            Self.legacyVideoInputVersionSHA256(
                asr: configuration.asr.derivationID,
                aligner: configuration.aligner.derivationID,
                embedding: configuration.embedding.derivationID
            )
        )
    }

    private func testConfiguration() -> ModelConfiguration {
        ModelConfiguration(
            schemaVersion: 1,
            omlx: .init(
                baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
                asrModelID: "asr-model",
                descriptionModelID: "description-model"
            ),
            worker: .init(
                forcedAlignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                pythonLauncherPath: "/usr/bin/python3",
                modelRootPath: "/tmp/media-memory-image-tests/Models"
            )
        )
    }

    /// 按图片支持引入前的原始公式重算视频配方摘要，用于锁定字节不变。
    private static func legacyVideoInputVersionSHA256(
        asr: String,
        aligner: String,
        embedding: String
    ) -> String {
        let source = [
            "segment-v1",
            SegmentIndexer.frameSelectionVersion,
            "vision-ocr-v1",
            asr,
            aligner,
            embedding
        ].joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func testReconcileWithChangedVideoVersionSparesImageEmbeddings() async throws {
        let temporary = try TestDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleImageAsset(relativePath: "photo.jpg")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileSegmentationJobs(
            algorithmVersionByKind: [MediaKind.image: "static-single-v1-image"]
        )
        let claimed = try await database.claimNextSegmentationJob()
        guard case let .target(segmentationTarget) = claimed else {
            return XCTFail("图片资产应有 segment_asset 任务")
        }
        try await database.commitSegmentation(
            claim: segmentationTarget.job.claimToken,
            assetID: segmentationTarget.asset.id,
            sourceFingerprint: segmentationTarget.asset.fingerprint,
            algorithmVersion: "static-single-v1-image",
            parametersJSON: "{\"algorithm_version\":\"static-single-v1-image\"}",
            segments: [SemanticSegmentDraft(startMS: 0, endMS: 1_000)]
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersionByKind: [MediaKind.video: "video-v1", MediaKind.image: "image-v1"]
        )
        let indexClaimed = try await database.claimNextIndexJob()
        guard case let .target(indexTarget) = indexClaimed else {
            return XCTFail("图片片段应有建库任务")
        }
        try await database.commitIndexOutput(
            claim: indexTarget.job.claimToken,
            segmentID: indexTarget.segment.id,
            output: testIndexOutput(fingerprint: indexTarget.asset.fingerprint),
            inputVersion: "image-v1"
        )

        // 视频配方变化 + 图片配方不变 → 图片向量保持当前，不重新入队。
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersionByKind: [MediaKind.video: "video-v2-changed", MediaKind.image: "image-v1"]
        )
        let afterVideoChange = try await database.claimNextIndexJob()
        guard case .idle = afterVideoChange else {
            return XCTFail("视频配方变化不应使图片向量失效")
        }

        // 图片配方变化 → 只图片向量失效。
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersionByKind: [MediaKind.video: "video-v2-changed", MediaKind.image: "image-v2-changed"]
        )
        let afterImageChange = try await database.claimNextIndexJob()
        guard case .target = afterImageChange else {
            return XCTFail("图片配方变化应重新入队图片片段")
        }
    }

    func testSemanticSearchLoadsEmbeddingsAcrossBothRecipes() async throws {
        let temporary = try TestDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleImageAsset(relativePath: "photo.jpg")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileSegmentationJobs(
            algorithmVersionByKind: [MediaKind.image: "static-single-v1-image"]
        )
        let claimed = try await database.claimNextSegmentationJob()
        guard case let .target(segmentationTarget) = claimed else {
            return XCTFail("图片资产应有 segment_asset 任务")
        }
        try await database.commitSegmentation(
            claim: segmentationTarget.job.claimToken,
            assetID: segmentationTarget.asset.id,
            sourceFingerprint: segmentationTarget.asset.fingerprint,
            algorithmVersion: "static-single-v1-image",
            parametersJSON: "{\"algorithm_version\":\"static-single-v1-image\"}",
            segments: [SemanticSegmentDraft(startMS: 0, endMS: 1_000)]
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersionByKind: [MediaKind.image: "image-v1"]
        )
        let indexClaimed = try await database.claimNextIndexJob()
        guard case let .target(indexTarget) = indexClaimed else {
            return XCTFail("图片片段应有建库任务")
        }
        try await database.commitIndexOutput(
            claim: indexTarget.job.claimToken,
            segmentID: indexTarget.segment.id,
            output: testIndexOutput(fingerprint: indexTarget.asset.fingerprint),
            inputVersion: "image-v1"
        )

        let stored = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersions: ["video-v1", "image-v1"]
        )
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.segmentID, indexTarget.segment.id)
        let empty = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersions: ["video-v1"]
        )
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: 图片抽帧与描述身份

    func testImageFrameExtractionProducesSingleNominalSample() async throws {
        let (directory, cleanup) = try makeImageDirectory()
        defer { cleanup() }
        let source = try writePNG(to: directory.appending(path: "picture.png"), width: 96, height: 64)
        let runDirectory = directory.appending(path: "frames", directoryHint: .isDirectory)

        let sample = try await FrameExtractor.extractImageAsset(
            assetURL: source,
            destinationDirectory: runDirectory
        )
        XCTAssertEqual(sample.timeMS, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.imageURL.path))

        // OCR 直接吃图片帧产物，与视频帧同构。
        let observations = try VisionTextRecognizer.recognize(frames: [sample])
        XCTAssertTrue(observations.allSatisfy { $0.startMS == 0 && $0.endMS == 1_000 })
    }

    func testDescriptionPromptVersionAndInputVersionAreKindScoped() {
        XCTAssertEqual(
            DescriptionService.promptVersion(for: .video),
            "observable-segment-description-v3"
        )
        XCTAssertEqual(
            DescriptionService.promptVersion(for: .image),
            "observable-image-description-v2"
        )
        XCTAssertNotEqual(
            DescriptionService.promptVersion(for: .video),
            DescriptionService.promptVersion(for: .image)
        )
        XCTAssertEqual(
            ContentSegmenter.algorithmFamily,
            "semantic-v2-visual-silence-v2"
        )
        XCTAssertEqual(
            ContentSegmenter.imageAlgorithmFamily,
            "static-single-v1"
        )
    }

    // MARK: Helpers

    /// 与 MediaDatabaseTests 相同形状的最小建库产物。
    private func testIndexOutput(fingerprint: String) -> SegmentIndexOutput {
        SegmentIndexOutput(
            sourceFingerprint: fingerprint,
            transcripts: [],
            ocr: [
                OCRObservationDraft(
                    text: "图片上的文字",
                    confidence: 0.9,
                    boxX: 0.1,
                    boxY: 0.1,
                    boxWidth: 0.4,
                    boxHeight: 0.2,
                    startMS: 0,
                    endMS: 1_000
                )
            ],
            frames: [
                SegmentFrameDraft(timeMS: 0, relativePath: "Frames/image-test/00-000000000000.jpg", perceptualHash: 0)
            ],
            embedding: EmbeddingVector(values: [0.25, -0.5, 0.75], norm: 1),
            asrModelID: "unused",
            alignerModelID: "unused",
            embeddingModelID: "embedding-model",
            runtimeVersion: "test"
        )
    }
}
