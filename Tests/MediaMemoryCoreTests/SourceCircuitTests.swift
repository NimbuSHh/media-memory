import Foundation
@testable import MediaMemoryCore
import XCTest

/// 源不可用断路（sourceUnavailable）：归一化、三车道停车零失败、
/// 代际恢复与退火降级。
final class SourceCircuitTests: XCTestCase {
    // MARK: SourceCircuitBoard

    func testCircuitBoardOpenIsIdempotentAndGenerationGuarded() async {
        let board = SourceCircuitBoard()
        let first = await board.beginOpen(rootID: "r", reason: "offline")
        XCTAssertEqual(first, .park)
        let again = await board.beginOpen(rootID: "r", reason: "另一个原因")
        XCTAssertEqual(again, .park, "已开路的根再次上报应保持首次原因并幂等停车")

        let circuit = await board.openCircuit(rootID: "r")
        XCTAssertEqual(circuit?.generation, 1)
        XCTAssertEqual(circuit?.reason, "offline")

        let wrongGeneration = await board.clear(rootID: "r", ifGeneration: 99)
        XCTAssertFalse(wrongGeneration, "代际不匹配不得解除")
        let stillBlocked = await board.isBlocked(rootID: "r")
        XCTAssertTrue(stillBlocked)

        let matched = await board.clear(rootID: "r", ifGeneration: 1)
        XCTAssertTrue(matched)
        let blocked = await board.isBlocked(rootID: "r")
        XCTAssertFalse(blocked)
    }

    func testStaleRecoveryCallbackDoesNotClearNewerCircuit() async {
        let board = SourceCircuitBoard()
        _ = await board.beginOpen(rootID: "r", reason: "第一轮")
        _ = await board.clear(rootID: "r", ifGeneration: 1)
        _ = await board.beginOpen(rootID: "r", reason: "第二轮")
        let stale = await board.clear(rootID: "r", ifGeneration: 1)
        XCTAssertFalse(stale, "旧恢复回调不得误清更新一轮断路")
        let stillOpen = await board.isBlocked(rootID: "r")
        XCTAssertTrue(stillOpen)
    }

    func testAnnealingDowngradesAfterTwoUnproductiveRecoveries() async {
        let board = SourceCircuitBoard()
        // 两个“开路 → 解除但无物化”周期。
        _ = await board.beginOpen(rootID: "r", reason: "x")
        _ = await board.clear(rootID: "r", ifGeneration: 1)
        let secondOpen = await board.beginOpen(rootID: "r", reason: "x")
        XCTAssertEqual(secondOpen, .park, "第一个无进展周期后仍应停车")
        _ = await board.clear(rootID: "r", ifGeneration: 2)
        let downgraded = await board.beginOpen(rootID: "r", reason: "x")
        XCTAssertEqual(downgraded, .failJob, "第二个无进展周期后应降级为单任务失败")
        let notBlocked = await board.isBlocked(rootID: "r")
        XCTAssertFalse(notBlocked, "降级不得建立断路")

        // 任一次成功物化即复位，恢复停车语义。
        await board.recordMaterialization(rootID: "r")
        let rehabilitated = await board.beginOpen(rootID: "r", reason: "x")
        XCTAssertEqual(rehabilitated, .park)
    }

    func testExplicitRetryClearsAllAndCountsAsRecovery() async {
        let board = SourceCircuitBoard()
        _ = await board.beginOpen(rootID: "a", reason: "x")
        _ = await board.beginOpen(rootID: "b", reason: "y")
        await board.clearAll()
        let ids = await board.blockedRootIDs()
        XCTAssertTrue(ids.isEmpty)
        // 两次“重试仍失败”后同样退火。
        _ = await board.beginOpen(rootID: "a", reason: "x")
        await board.clearAll()
        let downgraded = await board.beginOpen(rootID: "a", reason: "x")
        XCTAssertEqual(downgraded, .failJob)
    }

    // MARK: LocalSourceCache 归一化

    func testAuthorizationFailureIsNormalizedToSourceUnavailable() async throws {
        let temporary = try SourceCircuitTemporaryDirectory()
        let source = temporary.url.appending(path: "a.bin")
        try Data(repeating: 0x41, count: 4 * 1_024).write(to: source)
        let asset = try fixtureAsset(id: "asset-a", rootID: "root-x", source: source)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max },
            authorizeSource: { _ in throw SourceCircuitFixtureError.offline }
        )

        do {
            _ = try await cache.localURL(for: asset)
            XCTFail("授权失败应抛出 SourceUnavailableError")
        } catch let error as SourceUnavailableError {
            XCTAssertEqual(error.rootID, "root-x")
        } catch {
            XCTFail("授权失败应归一化为源不可用，实际：\(error)")
        }
    }

    func testMissingSourceFileIsNormalizedToSourceUnavailable() async throws {
        let temporary = try SourceCircuitTemporaryDirectory()
        let missing = temporary.url.appending(path: "missing.bin")
        let asset = try fixtureAsset(
            id: "asset-m",
            rootID: "root-y",
            source: missing,
            fingerprint: "missing-fingerprint"
        )
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )

        do {
            _ = try await cache.localURL(for: asset)
            XCTFail("源缺失应抛出 SourceUnavailableError")
        } catch let error as SourceUnavailableError {
            XCTAssertEqual(error.rootID, "root-y")
        } catch {
            XCTFail("源读取失败应归一化为源不可用，实际：\(error)")
        }
    }

    func testLocalCapacityErrorsAreNotNormalized() async throws {
        let temporary = try SourceCircuitTemporaryDirectory()
        let source = temporary.url.appending(path: "b.bin")
        try Data(repeating: 0x42, count: 4 * 1_024).write(to: source)
        let asset = try fixtureAsset(id: "asset-b", rootID: "root-z", source: source)
        let cache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 1 << 40,
            availableCapacity: { _ in 0 }
        )

        do {
            _ = try await cache.localURL(for: asset)
            XCTFail("本地空间不足应抛错")
        } catch let error as LocalSourceCacheError {
            guard case .insufficientSpace = error else {
                return XCTFail("预期 insufficientSpace，实际：\(error)")
            }
        } catch is SourceUnavailableError {
            XCTFail("本地容量问题不得归一化为源不可用")
        } catch {
            XCTFail("预期 insufficientSpace，实际：\(error)")
        }
    }

    // MARK: 三车道：停车零失败 + 降级失败

    func testSegmentationLaneParksWithoutFailingJobsAndDowngradesOnDemand() async throws {
        let fixture = try await makeParkedLaneFixture()
        let spy = SourceCircuitHandlerSpy()

        let parked = try await fixture.segmenter.runUntilIdle(
            onEvent: nil,
            onSourceUnavailable: { error in await spy.handle(error) }
        )
        XCTAssertEqual(parked, IndexRunSummary(succeeded: 0, failed: 0))
        let parkedProgress = try await fixture.segmenter.progress()
        XCTAssertEqual(parkedProgress.pending, 1, "停车时任务必须退回队列")
        XCTAssertEqual(parkedProgress.failed, 0, "停车不得产生失败任务")
        let received = await spy.receivedRootIDs()
        XCTAssertEqual(received, [fixture.rootID], "通知必须先于车道返回被处理")

        await spy.setDisposition(.failJob)
        let downgraded = try await fixture.segmenter.runUntilIdle(
            onEvent: nil,
            onSourceUnavailable: { error in await spy.handle(error) }
        )
        XCTAssertEqual(downgraded, IndexRunSummary(succeeded: 0, failed: 1))
        let downgradedProgress = try await fixture.segmenter.progress()
        XCTAssertEqual(downgradedProgress.failed, 1)
        XCTAssertEqual(downgradedProgress.pending, 0)
    }

    func testEvidenceLaneParksWithoutFailingJobs() async throws {
        let fixture = try await makeParkedLaneFixture()
        let indexer = SegmentIndexer(
            database: fixture.database,
            configuration: fixture.configuration,
            runtime: fixture.runtime,
            sourceCache: fixture.offlineSourceCache,
            workRoot: fixture.temporary.url
        )
        let spy = SourceCircuitHandlerSpy()

        let summary = try await indexer.runUntilIdle(
            onEvent: nil,
            onSourceUnavailable: { error in await spy.handle(error) }
        )
        XCTAssertEqual(summary, IndexRunSummary(succeeded: 0, failed: 0))
        let progress = try await indexer.progress()
        XCTAssertEqual(progress.pending, 1, "停车时任务必须退回队列")
        XCTAssertEqual(progress.failed, 0, "停车不得产生失败任务")
        let received = await spy.receivedRootIDs()
        XCTAssertEqual(received, [fixture.rootID])
    }

    func testDescriptionLaneParksWithoutFailingJobs() async throws {
        let fixture = try await makeParkedLaneFixture()
        // 描述任务以已提交的向量为前提：先经公共 API 补齐一条证据。
        try await fixture.commitEvidenceForSingleSegment()
        let descriptionService = DescriptionService(
            database: fixture.database,
            configuration: fixture.configuration,
            runtime: fixture.runtime,
            sourceCache: fixture.offlineSourceCache,
            workRoot: fixture.temporary.url
        )
        let queue = DescriptionQueue(
            database: fixture.database,
            descriptionService: descriptionService,
            sourceCache: fixture.offlineSourceCache
        )
        let spy = SourceCircuitHandlerSpy()

        let summary = try await queue.runUntilIdle(
            onEvent: nil,
            onSourceUnavailable: { error in await spy.handle(error) }
        )
        XCTAssertEqual(summary, IndexRunSummary(succeeded: 0, failed: 0))
        let progress = try await queue.progress()
        XCTAssertEqual(progress.pending, 1, "停车时任务必须退回队列")
        XCTAssertEqual(progress.failed, 0, "停车不得产生失败任务")
        let received = await spy.receivedRootIDs()
        XCTAssertEqual(received, [fixture.rootID])
    }
}

// MARK: - 夹具

private enum SourceCircuitFixtureError: Error {
    case offline
    case emptyClaim
}

private actor SourceCircuitHandlerSpy {
    private var rootIDs: [String] = []
    private var disposition: SourceUnavailableDisposition = .park

    func handle(_ error: SourceUnavailableError) -> SourceUnavailableDisposition {
        rootIDs.append(error.rootID)
        return disposition
    }

    func setDisposition(_ value: SourceUnavailableDisposition) {
        disposition = value
    }

    func receivedRootIDs() -> [String] {
        rootIDs
    }
}

private final class SourceCircuitTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "source-circuit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// 一套共享夹具：真实数据库 + 已 staged 的语义分片；离线源缓存使任何
/// 物化在授权一步即失败（不触达文件系统）。
private struct ParkedLaneFixture {
    let temporary: SourceCircuitTemporaryDirectory
    let database: MediaDatabase
    let configuration: ModelConfiguration
    let runtime: LocalModelRuntime
    let offlineSourceCache: LocalSourceCache
    let segmenter: ContentSegmenter
    let rootID: String
    let asset: MediaAssetRecord

    static func make() async throws -> ParkedLaneFixture {
        let temporary = try SourceCircuitTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([12])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    ScannedMediaAsset(
                        relativePath: "circuit.mp4",
                        standardizedPath: "/offline-volume/circuit.mp4",
                        fileIdentifier: nil,
                        fileSize: 1_024,
                        modificationDate: Date(),
                        durationMS: 10_000,
                        videoTrackCount: 1,
                        audioTrackCount: 1,
                        isPlayable: true,
                        fingerprint: "circuit-fingerprint",
                        status: .ready,
                        errorMessage: nil
                    )
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-circuit")
        let claim = try ParkedLaneFixture.segmentationClaim(
            try await database.claimNextSegmentationJob()
        )
        try await database.commitSegmentation(
            claim: claim.job.claimToken,
            assetID: claim.asset.id,
            sourceFingerprint: claim.asset.fingerprint,
            algorithmVersion: "semantic-circuit",
            parametersJSON: "{\"algorithm_version\":\"semantic-circuit\"}",
            segments: [.init(startMS: 0, endMS: 10_000)]
        )

        let offlineSourceCache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max },
            authorizeSource: { _ in throw SourceCircuitFixtureError.offline }
        )
        let extractor: ContentSegmenter.FeatureExtractor = { _, _ in
            TimelineFeatureExtractionResult(durationMS: 10_000, candidates: [])
        }
        let segmenter = ContentSegmenter(
            database: database,
            sourceCache: offlineSourceCache,
            extractFeatures: extractor
        )
        let configuration = httpConfiguration()
        let runtime = try LocalModelRuntime(
            configuration: configuration,
            credentials: ModelCredentials(),
            workRoot: temporary.url
        )
        return ParkedLaneFixture(
            temporary: temporary,
            database: database,
            configuration: configuration,
            runtime: runtime,
            offlineSourceCache: offlineSourceCache,
            segmenter: segmenter,
            rootID: root.id,
            asset: claim.asset
        )
    }

    /// 直接经公共 API 认领并提交证据，为描述车道制造前提；证据提交本身
    /// 不触源，因此不经过离线授权缓存。
    func commitEvidenceForSingleSegment() async throws {
        try await database.reconcileIndexJobs(
            embeddingModelID: configuration.embedding.derivationID,
            inputVersion: SegmentIndexer.inputVersion(for: configuration)
        )
        let target = try Self.indexClaim(try await database.claimNextIndexJob())
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    .init(
                        text: "fixture",
                        language: "Chinese",
                        startMS: 0,
                        endMS: 1_000,
                        timingSource: "asr_block"
                    )
                ],
                ocr: [],
                frames: [
                    .init(
                        timeMS: 0,
                        relativePath: "Frames/circuit/0.jpg",
                        perceptualHash: 1
                    )
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: configuration.asr.derivationID,
                alignerModelID: configuration.aligner.derivationID,
                embeddingModelID: configuration.embedding.derivationID,
                runtimeVersion: "circuit-test"
            ),
            inputVersion: SegmentIndexer.inputVersion(for: configuration)
        )
    }

    private static func segmentationClaim(
        _ claim: AssetSegmentationClaim
    ) throws -> AssetSegmentationTarget {
        guard case let .target(value) = claim else {
            throw SourceCircuitFixtureError.emptyClaim
        }
        return value
    }

    private static func indexClaim(_ claim: JobClaim) throws -> SegmentIndexTarget {
        guard case let .target(value) = claim else {
            throw SourceCircuitFixtureError.emptyClaim
        }
        return value
    }
}

private extension XCTestCase {
    func makeParkedLaneFixture() async throws -> ParkedLaneFixture {
        try await ParkedLaneFixture.make()
    }
}

private func httpConfiguration() -> ModelConfiguration {
    ModelConfiguration(
        asr: ModelEndpoint(
            transport: .openAITranscription,
            endpointURL: URL(string: "http://127.0.0.1:9/v1/audio/transcriptions"),
            modelID: "asr"
        ),
        aligner: ModelEndpoint(
            transport: .mediaMemoryAlignment,
            endpointURL: URL(string: "http://127.0.0.1:9/align"),
            modelID: "aligner"
        ),
        embedding: ModelEndpoint(
            transport: .mediaMemoryEmbedding,
            endpointURL: URL(string: "http://127.0.0.1:9/embed"),
            modelID: "embedding"
        ),
        description: ModelEndpoint(
            transport: .openAIChatCompletion,
            endpointURL: URL(string: "http://127.0.0.1:9/v1/chat/completions"),
            modelID: "description"
        ),
        localWorker: nil
    )
}

private func fixtureAsset(
    id: String,
    rootID: String,
    source: URL,
    fingerprint explicitFingerprint: String? = nil
) throws -> MediaAssetRecord {
    // 显式指纹供"源文件不存在"类夹具使用：跳过 snapshot，避免夹具自身
    // 在被测路径之前抛出文件系统错误。
    let resolvedFingerprint: String
    let fileSize: Int64
    let modificationDate: Date
    if let explicitFingerprint {
        resolvedFingerprint = explicitFingerprint
        fileSize = 1_024
        modificationDate = Date()
    } else {
        let snapshot = try FileFingerprint.snapshot(for: source)
        fileSize = snapshot.fileSize
        modificationDate = snapshot.modificationDate
        resolvedFingerprint = try FileFingerprint.lightFingerprint(
            for: source,
            snapshot: snapshot
        )
    }
    return MediaAssetRecord(
        id: id,
        rootID: rootID,
        relativePath: source.lastPathComponent,
        standardizedPath: source.path,
        fileSize: fileSize,
        modificationDate: modificationDate,
        durationMS: 1_000,
        videoTrackCount: 1,
        audioTrackCount: 1,
        isPlayable: true,
        fingerprint: resolvedFingerprint,
        status: .ready,
        errorMessage: nil,
        firstSeenAt: Date(),
        lastSeenAt: Date()
    )
}
