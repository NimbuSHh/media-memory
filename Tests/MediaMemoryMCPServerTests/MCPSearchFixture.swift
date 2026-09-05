import Foundation
@testable import MediaMemoryCore
@testable import MediaMemoryMCPServer

/// 端到端会话测试的数据底座：与 SearchServiceTests 的 SearchFixture 相同的
/// 提交路径（扫描 → 建库任务 → 证据+向量原子提交），随后按生产拓扑打开
/// 只读连接供检索服务使用。
final class MCPSearchFixture: @unchecked Sendable {
    enum FixtureError: Error {
        case missingJob
    }

    let root: URL
    let databaseURL: URL
    let configuration: ModelConfiguration
    let segmentID: String

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "media-memory-mcp-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appending(path: "test.sqlite")
        let writer = try MediaDatabase(url: databaseURL)
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
        let library = try await writer.addLibraryRoot(path: root.path, bookmark: Data([1]))
        try await writer.applyScan(
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
        try await writer.reconcileIndexJobs(
            embeddingModelID: configuration.embedding.derivationID,
            inputVersion: inputVersion
        )
        guard case .target(let target) = try await writer.claimNextIndexJob() else {
            throw FixtureError.missingJob
        }
        segmentID = target.segment.id
        try await writer.commitIndexOutput(
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

    /// 与生产一致的只读检索面。
    func makeBackend() async throws -> MediaMemorySearchBackend {
        let readOnly = try MediaDatabase(readOnlyURL: databaseURL)
        let search = SearchService(database: readOnly, configuration: configuration)
        return MediaMemorySearchBackend(
            searchService: search,
            database: readOnly,
            modelSummary: "test-summary"
        )
    }
}
