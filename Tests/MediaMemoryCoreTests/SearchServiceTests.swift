import Foundation
@testable import MediaMemoryCore
import XCTest

final class SearchServiceTests: XCTestCase {
    func testSearchWithoutRuntimeReturnsLiteralResults() async throws {
        let fixture = try await SearchFixture()
        let search = SearchService(
            database: fixture.database,
            configuration: fixture.configuration
        )

        let immediate = try await search.literalSearch("京都车站")
        XCTAssertEqual(immediate.first?.segment.id, fixture.segmentID)
        XCTAssertNil(immediate.first?.semanticScore)

        let results = try await search.search("京都车站")

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.segment.id, fixture.segmentID)
        XCTAssertEqual(result.literalScore, 1)
        XCTAssertNil(result.semanticScore)
        XCTAssertEqual(result.evidence.first?.kind, .transcript)
        XCTAssertTrue(result.evidence.first?.text.contains("京都车站") == true)
    }

    func testSemanticFailureDoesNotDiscardLiteralResults() async throws {
        let fixture = try await SearchFixture()
        let runtime = try LocalModelRuntime(
            configuration: fixture.configuration,
            apiKey: "test-key",
            workRoot: fixture.root
        )
        let search = SearchService(
            database: fixture.database,
            configuration: fixture.configuration,
            runtime: runtime
        )

        // The fixture intentionally has no embedding model directory, so the
        // semantic branch fails before starting a Worker process.
        let results = try await search.search("京都车站")

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.segment.id, fixture.segmentID)
        XCTAssertEqual(result.literalScore, 1)
        XCTAssertNil(result.semanticScore)
    }

    func testVisualDescriptionCompletesLiteralRecallWithoutIndexingUncertainty() async throws {
        let fixture = try await SearchFixture()
        try await fixture.saveDescription(
            summary: "一名行人在海边看日落。",
            visibleDetails: ["远处有一艘白色帆船。"],
            uncertainty: ["无法确认岸边是否停着红色汽车。"]
        )
        let search = SearchService(
            database: fixture.database,
            configuration: fixture.configuration
        )

        let summaryResults = try await search.literalSearch("海边看日落")
        XCTAssertEqual(summaryResults.first?.segment.id, fixture.segmentID)
        XCTAssertEqual(summaryResults.first?.evidence.first?.kind, .visual)

        let detailResults = try await search.literalSearch("白色帆船")
        XCTAssertEqual(detailResults.first?.segment.id, fixture.segmentID)
        XCTAssertEqual(detailResults.first?.evidence.first?.kind, .visual)

        let uncertainResults = try await search.literalSearch("红色汽车")
        XCTAssertTrue(uncertainResults.isEmpty)

        let derivationContext = try await fixture.database.searchContext(
            segmentID: fixture.segmentID
        )
        XCTAssertFalse(derivationContext?.evidence.contains { $0.kind == .visual } == true)
    }

    func testReplacingVisualDescriptionRemovesStaleRecall() async throws {
        let fixture = try await SearchFixture()
        try await fixture.saveDescription(summary: "画面中有蓝色雨伞。")
        try await fixture.saveDescription(summary: "画面中有黄色雨衣。")

        let oldMatches = try await fixture.database.literalSearch(query: "蓝色雨伞")
        XCTAssertTrue(oldMatches.isEmpty)
        let newMatches = try await fixture.database.literalSearch(query: "黄色雨衣")
        XCTAssertEqual(newMatches.first?.evidence.kind, .visual)
    }

    func testLiteralPhasePreservesDatabaseRelevanceOrder() async throws {
        let fixture = try await SearchFixture()
        let strongerSegmentID = try await fixture.indexNext(transcript: "京都车站")
        let databaseMatches = try await fixture.database.literalSearch(query: "京都车站")
        XCTAssertEqual(databaseMatches.first?.segmentID, strongerSegmentID)

        let search = SearchService(
            database: fixture.database,
            configuration: fixture.configuration
        )
        let results = try await search.literalSearch("京都车站")

        XCTAssertEqual(results.count, 1, "同一视频的多个命中片段必须聚合成一行")
        XCTAssertEqual(results.first?.segment.id, strongerSegmentID)
        XCTAssertEqual(results.first?.matchedSegmentCount, 2)
        XCTAssertEqual(results.first?.asrMatchCount, 3)
        XCTAssertEqual(results.first?.ocrMatchCount, 1)
        XCTAssertEqual(results.first?.literalScore, 1)
        XCTAssertNotNil(results.first?.bm25Score)

        let shortQueryResults = try await search.literalSearch("车站")
        XCTAssertEqual(shortQueryResults.count, 1)
        XCTAssertEqual(shortQueryResults.first?.literalScore, 1)
        XCTAssertNil(shortQueryResults.first?.bm25Score, "两字查询走子串匹配，不应伪报 BM25")
    }

    func testCombinedRelevanceRewardsStrengthAndIndependentSignals() {
        let topLiteral = SearchService.literalRelevance(rank: 0)
        let lowerLiteral = SearchService.literalRelevance(rank: 10)
        XCTAssertGreaterThan(topLiteral, lowerLiteral)

        let literalOnly = SearchService.combinedRelevance(
            literalScore: topLiteral,
            semanticScore: nil
        )
        let semanticOnly = SearchService.combinedRelevance(
            literalScore: 0,
            semanticScore: 1
        )
        let both = SearchService.combinedRelevance(
            literalScore: topLiteral,
            semanticScore: 0.8
        )
        XCTAssertGreaterThan(literalOnly, semanticOnly)
        XCTAssertGreaterThan(both, literalOnly)
        XCTAssertGreaterThan(
            SearchService.combinedRelevance(literalScore: 0, semanticScore: 0.8),
            SearchService.combinedRelevance(literalScore: 0, semanticScore: 0.2)
        )
        XCTAssertEqual(
            SearchService.combinedRelevance(literalScore: 0, semanticScore: -0.5),
            0
        )
    }

    func testEvidenceShowsEveryMatchedSourceOnce() async throws {
        let fixture = try await SearchFixture()
        try await fixture.saveDescription(summary: "画面显示京都车站的入口。")
        let search = SearchService(
            database: fixture.database,
            configuration: fixture.configuration
        )

        let results = try await search.literalSearch("京都车站")
        let result = try XCTUnwrap(results.first)

        XCTAssertEqual(result.evidence.map(\.kind), [.visual, .transcript, .ocr])
        XCTAssertEqual(result.evidence.filter { $0.kind == .transcript }.count, 1)
        XCTAssertEqual(result.matchedSegmentCount, 1)
        XCTAssertEqual(result.visualDescriptionSegmentCount, 1)
        XCTAssertEqual(result.asrMatchCount, 2)
        XCTAssertEqual(result.ocrMatchCount, 1)
        XCTAssertNotNil(result.bm25Score)
    }
}

private final class SearchFixture: @unchecked Sendable {
    let root: URL
    let database: MediaDatabase
    let configuration: ModelConfiguration
    private(set) var segmentID = ""

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "media-memory-search-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try MediaDatabase(url: root.appending(path: "test.sqlite"))
        configuration = ModelConfiguration(
            schemaVersion: 1,
            omlx: .init(
                baseURL: URL(string: "http://127.0.0.1:1/v1")!,
                asrModelID: "asr-model",
                descriptionModelID: "description-model"
            ),
            worker: .init(
                forcedAlignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                pythonLauncherPath: "/usr/bin/python3",
                modelRootPath: root.appending(path: "missing-models").path
            )
        )
        let library = try await database.addLibraryRoot(
            path: root.path,
            bookmark: Data([1])
        )
        try await database.applyScan(
            rootID: library.id,
            result: MediaScanResult(
                assets: [
                    ScannedMediaAsset(
                        relativePath: "clip.mp4",
                        standardizedPath: root.appending(path: "clip.mp4").path,
                        fileIdentifier: "clip-file-id",
                        fileSize: 1_024,
                        modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                        durationMS: 40_000,
                        videoTrackCount: 1,
                        audioTrackCount: 1,
                        isPlayable: true,
                        fingerprint: "stable-fingerprint",
                        status: .ready,
                        errorMessage: nil
                    )
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let inputVersion = SegmentIndexer.inputVersion(for: configuration)
        try await database.reconcileIndexJobs(
            embeddingModelID: configuration.embedding.derivationID,
            inputVersion: inputVersion
        )
        guard case .target(let target) = try await database.claimNextIndexJob() else {
            throw SearchFixtureError.missingJob
        }
        segmentID = target.segment.id
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    TranscriptSentenceDraft(
                        text: "我们在京都车站讨论晚饭。",
                        language: "Chinese",
                        startMS: 100,
                        endMS: 2_000,
                        timingSource: "forced_alignment_sentence"
                    ),
                    TranscriptSentenceDraft(
                        text: "京都车站附近人很多。",
                        language: "Chinese",
                        startMS: 2_100,
                        endMS: 3_500,
                        timingSource: "forced_alignment_sentence"
                    )
                ],
                ocr: [
                    OCRObservationDraft(
                        text: "站牌写着京都车站",
                        confidence: 0.95,
                        boxX: 0.1,
                        boxY: 0.1,
                        boxWidth: 0.5,
                        boxHeight: 0.1,
                        startMS: 500,
                        endMS: 1_500
                    )
                ],
                frames: [],
                embedding: EmbeddingVector(values: [1, 0], norm: 1),
                asrModelID: configuration.asr.derivationID,
                alignerModelID: configuration.aligner.derivationID,
                embeddingModelID: configuration.embedding.derivationID,
                runtimeVersion: "test"
            ),
            inputVersion: inputVersion
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func saveDescription(
        summary: String,
        visibleDetails: [String] = [],
        uncertainty: [String] = []
    ) async throws {
        let revision = try await database.descriptionInputRevision(segmentID: segmentID)
        guard let revision else { throw SearchFixtureError.missingDescriptionRevision }
        try await database.saveDescription(
            segmentID: segmentID,
            sourceFingerprint: "stable-fingerprint",
            expectedInputRevision: revision,
            modelID: configuration.description.derivationID,
            runtimeVersion: "test",
            promptVersion: "test-prompt",
            inputVersion: "test-input",
            description: SegmentDescription(
                summary: summary,
                visibleDetails: visibleDetails,
                uncertainty: uncertainty
            )
        )
    }

    func indexNext(transcript: String) async throws -> String {
        guard case .target(let target) = try await database.claimNextIndexJob() else {
            throw SearchFixtureError.missingJob
        }
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    TranscriptSentenceDraft(
                        text: transcript,
                        language: "Chinese",
                        startMS: target.segment.startMS + 100,
                        endMS: target.segment.startMS + 2_000,
                        timingSource: "forced_alignment_sentence"
                    )
                ],
                ocr: [],
                frames: [],
                embedding: EmbeddingVector(values: [0, 1], norm: 1),
                asrModelID: configuration.asr.derivationID,
                alignerModelID: configuration.aligner.derivationID,
                embeddingModelID: configuration.embedding.derivationID,
                runtimeVersion: "test"
            ),
            inputVersion: SegmentIndexer.inputVersion(for: configuration)
        )
        return target.segment.id
    }
}

private enum SearchFixtureError: Error {
    case missingJob
    case missingDescriptionRevision
}
