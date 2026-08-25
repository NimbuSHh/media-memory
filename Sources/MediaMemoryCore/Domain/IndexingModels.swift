import Foundation

public enum JobStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
}

public enum JobKind: String, Codable, Sendable {
    case segmentAsset = "segment_asset"
    case indexSegment = "index_segment"
    case describeSegment = "describe_segment"
}

/// A claim is valid only while the job is still running with this exact attempt.
/// Recovered or re-claimed work receives a different attempt and cannot mutate state.
public struct JobClaimToken: Equatable, Sendable {
    public let jobID: String
    public let attemptCount: Int

    public init(jobID: String, attemptCount: Int) {
        self.jobID = jobID
        self.attemptCount = attemptCount
    }
}

public struct IndexJobRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let assetID: String
    public let segmentID: String
    public let status: JobStatus
    public let attemptCount: Int
    public let stage: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var claimToken: JobClaimToken {
        JobClaimToken(jobID: id, attemptCount: attemptCount)
    }
}

public struct IndexingProgress: Equatable, Sendable {
    public let total: Int
    public let pending: Int
    public let running: Int
    public let succeeded: Int
    public let failed: Int

    public init(total: Int, pending: Int, running: Int, succeeded: Int, failed: Int) {
        self.total = total
        self.pending = pending
        self.running = running
        self.succeeded = succeeded
        self.failed = failed
    }

    public var completed: Int { succeeded + failed }
    public var fractionCompleted: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

/// 失败任务的摘要：界面展示失败原因用。
public struct FailedJobSummary: Identifiable, Equatable, Sendable {
    public var id: String { jobID }
    public let jobID: String
    public let assetName: String
    public let segmentOrdinal: Int?
    public let kind: String
    public let message: String
    public let updatedAt: Date

    public var kindName: String {
        switch kind {
        case JobKind.segmentAsset.rawValue: "语义分片"
        case JobKind.describeSegment.rawValue: "描述"
        default: "建库"
        }
    }
}

public struct AssetSegmentationJobRecord: Equatable, Sendable {
    public let id: String
    public let assetID: String
    public let status: JobStatus
    public let attemptCount: Int
    public let stage: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var claimToken: JobClaimToken {
        JobClaimToken(jobID: id, attemptCount: attemptCount)
    }
}

public struct AssetSegmentationTarget: Equatable, Sendable {
    public let job: AssetSegmentationJobRecord
    public let asset: MediaAssetRecord
}

public enum AssetSegmentationClaim: Equatable, Sendable {
    case target(AssetSegmentationTarget)
    case idle
}

public struct SemanticSegmentDraft: Equatable, Sendable {
    public let startMS: Int64
    public let endMS: Int64

    public init(startMS: Int64, endMS: Int64) {
        self.startMS = startMS
        self.endMS = endMS
    }
}

public enum TimelineBoundaryKind: String, Codable, Sendable {
    case visualChange = "visual_change"
    case silenceEnd = "silence_end"
}

/// Auditable source-timeline evidence used by the segmentation planner. These
/// observations are not representative frames and do not own segment ranges.
public struct TimelineBoundaryObservationDraft: Equatable, Sendable {
    public let timeMS: Int64
    public let kind: TimelineBoundaryKind
    public let score: Double
    public let detailsJSON: String

    public init(
        timeMS: Int64,
        kind: TimelineBoundaryKind,
        score: Double,
        detailsJSON: String
    ) {
        self.timeMS = timeMS
        self.kind = kind
        self.score = score
        self.detailsJSON = detailsJSON
    }
}

public struct TimelineBoundaryObservationRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let derivationRunID: String
    public let assetID: String
    public let timeMS: Int64
    public let kind: TimelineBoundaryKind
    public let score: Double
    public let detailsJSON: String
}

/// 任务认领结果。两条车道独立消费各自的队列，不存在跨车道门控状态。
public enum JobClaim: Equatable, Sendable {
    case target(SegmentIndexTarget)
    case idle
}

public struct SegmentIndexTarget: Equatable, Sendable {
    public let job: IndexJobRecord
    public let asset: MediaAssetRecord
    public let segment: SegmentRecord
    /// 描述任务认领时所基于的证据 revision；证据任务为 nil。
    public let descriptionInputRevision: String?
}

public struct SegmentFrameDraft: Equatable, Sendable {
    public let timeMS: Int64
    public let relativePath: String
    public let perceptualHash: UInt64
}

public struct SegmentFrameRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let segmentID: String
    public let ordinal: Int
    public let timeMS: Int64
    public let relativePath: String
    public let perceptualHash: UInt64
}

public struct TranscriptEvidenceRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let segmentID: String
    public let text: String
    public let language: String?
    public let startMS: Int64
    public let endMS: Int64
    public let timingSource: String
}

public struct OCREvidenceRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let segmentID: String
    public let text: String
    public let confidence: Double
    public let startMS: Int64
    public let endMS: Int64
}

public struct SegmentIndexOutput: Sendable {
    public let sourceFingerprint: String
    public let transcripts: [TranscriptSentenceDraft]
    public let ocr: [OCRObservationDraft]
    public let frames: [SegmentFrameDraft]
    public let embedding: EmbeddingVector
    public let asrModelID: String
    public let alignerModelID: String
    public let embeddingModelID: String
    public let runtimeVersion: String

    public init(
        sourceFingerprint: String,
        transcripts: [TranscriptSentenceDraft],
        ocr: [OCRObservationDraft],
        frames: [SegmentFrameDraft],
        embedding: EmbeddingVector,
        asrModelID: String,
        alignerModelID: String,
        embeddingModelID: String,
        runtimeVersion: String
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.transcripts = transcripts
        self.ocr = ocr
        self.frames = frames
        self.embedding = embedding
        self.asrModelID = asrModelID
        self.alignerModelID = alignerModelID
        self.embeddingModelID = embeddingModelID
        self.runtimeVersion = runtimeVersion
    }
}

public enum SearchEvidenceKind: String, Codable, Hashable, Sendable {
    /// Qwen 画面描述中的可观察内容；不是 ASR 或 OCR 原文。
    case visual
    case transcript
    case ocr
}

public struct SearchEvidence: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: SearchEvidenceKind
    public let text: String
    public let startMS: Int64
    public let endMS: Int64
}

public struct LiteralSearchMatch: Equatable, Sendable {
    public let segmentID: String
    public let evidence: SearchEvidence
    public let rank: Double
}

public struct LiteralSearchSnapshot: Sendable {
    public let matches: [LiteralSearchMatch]
    public let contexts: [String: SegmentSearchContext]

    public init(
        matches: [LiteralSearchMatch],
        contexts: [String: SegmentSearchContext]
    ) {
        self.matches = matches
        self.contexts = contexts
    }
}

public struct StoredEmbedding: Equatable, Sendable {
    public let segmentID: String
    public let values: [Float]
}

public struct SegmentSearchContext: Equatable, Sendable {
    public let segment: SegmentRecord
    public let asset: MediaAssetRecord
    public let evidence: [SearchEvidence]
}

public struct SearchResult: Identifiable, Equatable, Sendable {
    public var id: String { segment.id }
    public let asset: MediaAssetRecord
    public let segment: SegmentRecord
    public let evidence: [SearchEvidence]
    public let literalScore: Double
    /// 原始余弦相似度；nil 表示本次查询没有可用的语义分支。
    public let semanticScore: Double?
    /// FTS5 bm25 的正向显示分（对 SQLite 原始负值取反）；短词回退搜索时为 nil。
    public let bm25Score: Double?
    public let combinedScore: Double
    /// 当前视频进入候选集的片段数；结果列表按视频聚合后每个视频只出现一次。
    public let matchedSegmentCount: Int
    public let visualDescriptionSegmentCount: Int
    public let asrMatchCount: Int
    public let ocrMatchCount: Int
    public let playbackStartMS: Int64
    public let playbackEndMS: Int64
}

public struct AssetSegmentInfo: Identifiable, Equatable, Sendable {
    public var id: String { segment.id }
    public let segment: SegmentRecord
    public let isIndexed: Bool
    public let frameCount: Int
    /// 描述车道任务状态；未入队或片段尚未建库时为 nil。
    public let describeStatus: JobStatus?

    public init(
        segment: SegmentRecord,
        isIndexed: Bool,
        frameCount: Int,
        describeStatus: JobStatus? = nil
    ) {
        self.segment = segment
        self.isIndexed = isIndexed
        self.frameCount = frameCount
        self.describeStatus = describeStatus
    }
}

public struct AssetLibraryDetail: Equatable, Sendable {
    public let segments: [AssetSegmentInfo]
    public let transcripts: [TranscriptEvidenceRecord]
    public let ocr: [OCREvidenceRecord]
    public let frames: [SegmentFrameRecord]

    public init(
        segments: [AssetSegmentInfo],
        transcripts: [TranscriptEvidenceRecord],
        ocr: [OCREvidenceRecord],
        frames: [SegmentFrameRecord] = []
    ) {
        self.segments = segments
        self.transcripts = transcripts
        self.ocr = ocr
        self.frames = frames
    }

    public var indexedSegmentCount: Int { segments.filter(\.isIndexed).count }

    public var transcriptsBySegment: [String: [TranscriptEvidenceRecord]] {
        Dictionary(grouping: transcripts, by: \.segmentID)
    }

    public var ocrBySegment: [String: [OCREvidenceRecord]] {
        Dictionary(grouping: ocr, by: \.segmentID)
    }

    public var framesBySegment: [String: [SegmentFrameRecord]] {
        Dictionary(grouping: frames, by: \.segmentID)
    }
}

/// 单个视频的处理进度汇总，用于视频卡片与队列总览。
/// 证据链（ASR/对齐/OCR/向量）按片段原子提交，四个模型共享同一进度数；
/// `currentStage` 指出当前正在跑的是哪个模型环节。
public struct AssetProcessingSummary: Equatable, Sendable {
    public let assetID: String
    public let segmentationStatus: JobStatus?
    public let segmentationStage: String?
    public let totalSegments: Int
    public let indexedSegments: Int
    public let evidenceSucceeded: Int
    public let evidencePending: Int
    public let evidenceRunning: Bool
    public let evidenceFailed: Int
    public let currentStage: String?
    public let currentSegmentOrdinal: Int?
    public let describeSucceeded: Int
    public let describePending: Int
    public let describeRunning: Bool
    public let describeFailed: Int

    public var isProcessing: Bool {
        segmentationStatus == .running || evidenceRunning || describeRunning
            || segmentationStatus == .pending
            || evidencePending > 0 || describePending > 0
    }

    public var failedCount: Int {
        (segmentationStatus == .failed || segmentationStatus == .cancelled ? 1 : 0)
            + evidenceFailed + describeFailed
    }
}

/// One WAL snapshot for the library screen. Roots, visible assets and their
/// processing badges must describe the same committed database state.
public struct MediaLibrarySnapshot: Sendable {
    public let roots: [LibraryRootRecord]
    public let assets: [MediaAssetRecord]
    public let processingSummaries: [String: AssetProcessingSummary]

    public init(
        roots: [LibraryRootRecord],
        assets: [MediaAssetRecord],
        processingSummaries: [String: AssetProcessingSummary]
    ) {
        self.roots = roots
        self.assets = assets
        self.processingSummaries = processingSummaries
    }
}

/// One WAL snapshot for queue progress and failures. A background commit may
/// appear on the next refresh, but cannot split one dashboard refresh in half.
public struct JobDashboardSnapshot: Sendable {
    public let jobs: [IndexJobRecord]
    public let failures: [FailedJobSummary]
    public let indexingProgress: IndexingProgress
    public let describeProgress: IndexingProgress
    public let staleDescriptionCount: Int
    public let processingSummaries: [String: AssetProcessingSummary]

    public init(
        jobs: [IndexJobRecord],
        failures: [FailedJobSummary],
        indexingProgress: IndexingProgress,
        describeProgress: IndexingProgress,
        staleDescriptionCount: Int,
        processingSummaries: [String: AssetProcessingSummary]
    ) {
        self.jobs = jobs
        self.failures = failures
        self.indexingProgress = indexingProgress
        self.describeProgress = describeProgress
        self.staleDescriptionCount = staleDescriptionCount
        self.processingSummaries = processingSummaries
    }
}

/// 片段描述是 Qwen3.8 的视觉理解输出，只覆盖它能实际观察的内容：
/// 关键帧画面，加上输入中提供的 ASR/OCR 证据。语音的权威来源是 ASR
/// 证据，画面文字的权威来源是 OCR 证据——描述不重复、不冒充它们。
public struct SegmentDescription: Codable, Equatable, Sendable {
    public let summary: String
    public let visibleDetails: [String]
    public let uncertainty: [String]

    public init(summary: String, visibleDetails: [String], uncertainty: [String]) {
        self.summary = summary
        self.visibleDetails = visibleDetails
        self.uncertainty = uncertainty
    }
}

extension SegmentDescription {
    /// uncertainty 描述的是无法确认的内容，不能作为正向检索命中。
    var searchableVisualTexts: [String] {
        ([summary] + visibleDetails).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

public struct CachedSegmentDescription: Equatable, Sendable {
    public let description: SegmentDescription
    public let inputVersion: String
    public let promptVersion: String
    public let modelID: String
    public let createdAt: Date
}
