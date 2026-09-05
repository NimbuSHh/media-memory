import CryptoKit
import Foundation

public enum DescriptionServiceError: Error, LocalizedError, Sendable {
    case missingSegment
    case missingFrames
    case frameOutsideWorkDirectory

    public var errorDescription: String? {
        switch self {
        case .missingSegment:
            "片段已经不存在。"
        case .missingFrames:
            "片段代表帧缺失，请重试该建库任务。"
        case .frameOutsideWorkDirectory:
            "数据库中的代表帧路径越过了应用工作目录。"
        }
    }
}

public actor DescriptionService {
    /// 每种媒体类型独立的描述 prompt 身份。v3/v2 起 JSON 形状改由提示词
    /// 约定（grammar 约束与 oMLX 原生 MTP 投机解码互斥），改版本会让对应
    /// 存量描述被判为旧版，等待手动刷新。
    public static let promptVersion = "observable-segment-description-v3"
    public static let imagePromptVersion = "observable-image-description-v2"

    public static func promptVersion(for kind: MediaKind) -> String {
        switch kind {
        case .video: promptVersion
        case .image: imagePromptVersion
        }
    }

    private let database: MediaDatabase
    private let configuration: ModelConfiguration
    private let runtime: LocalModelRuntime
    private let sourceCache: LocalSourceCache
    private let workRoot: URL

    public init(
        database: MediaDatabase,
        configuration: ModelConfiguration,
        runtime: LocalModelRuntime,
        sourceCache: LocalSourceCache,
        workRoot: URL
    ) {
        self.database = database
        self.configuration = configuration
        self.runtime = runtime
        self.sourceCache = sourceCache
        self.workRoot = workRoot.standardizedFileURL
    }

    public var descriptionModelID: String { configuration.description.derivationID }

    /// 展示用：最新缓存描述，不校验版本；调用方负责提示旧版。
    public func latestDescription(segmentID: String) async throws -> CachedSegmentDescription? {
        try await database.latestDescription(segmentID: segmentID)
    }

    public func latestDescriptions(assetID: String) async throws -> [String: CachedSegmentDescription] {
        try await database.latestDescriptions(assetID: assetID)
    }

    public func cachedDescription(segmentID: String) async throws -> CachedSegmentDescription? {
        guard let prepared = try? await prepareInput(segmentID: segmentID) else { return nil }
        return try await database.cachedDescription(
            segmentID: segmentID,
            inputVersion: prepared.inputVersion
        )
    }

    public func description(segmentID: String) async throws -> CachedSegmentDescription {
        let prepared = try await prepareInput(segmentID: segmentID)
        if let cached = try await database.cachedDescription(
            segmentID: segmentID,
            inputVersion: prepared.inputVersion
        ) {
            return cached
        }
        let value = try await generate(prepared)
        try await database.saveDescription(
            segmentID: segmentID,
            sourceFingerprint: prepared.context.asset.fingerprint,
            expectedInputRevision: prepared.revision,
            modelID: configuration.description.derivationID,
            runtimeVersion: SegmentIndexer.runtimeVersion,
            promptVersion: Self.promptVersion(for: prepared.context.asset.mediaKind),
            inputVersion: prepared.inputVersion,
            description: value
        )
        guard let saved = try await database.cachedDescription(
            segmentID: segmentID,
            inputVersion: prepared.inputVersion
        ) else {
            throw DescriptionServiceError.missingSegment
        }
        return saved
    }

    /// 后台描述车道入口：描述写入与 job 完成在数据库中原子提交。
    public func description(for target: SegmentIndexTarget) async throws -> CachedSegmentDescription {
        guard let expectedRevision = target.descriptionInputRevision else {
            throw MediaDatabaseDerivationError.descriptionInputChanged
        }
        let prepared = try await prepareInput(
            segmentID: target.segment.id,
            expectedRevision: expectedRevision
        )
        if let cached = try await database.cachedDescription(
            segmentID: target.segment.id,
            inputVersion: prepared.inputVersion
        ) {
            try await database.completeDescribeJob(
                claim: target.job.claimToken,
                expectedInputRevision: prepared.revision
            )
            return cached
        }
        let value = try await generate(prepared)
        try await database.commitDescription(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            sourceFingerprint: prepared.context.asset.fingerprint,
            expectedInputRevision: prepared.revision,
            modelID: configuration.description.derivationID,
            runtimeVersion: SegmentIndexer.runtimeVersion,
            promptVersion: Self.promptVersion(for: prepared.context.asset.mediaKind),
            inputVersion: prepared.inputVersion,
            description: value
        )
        guard let saved = try await database.cachedDescription(
            segmentID: target.segment.id,
            inputVersion: prepared.inputVersion
        ) else {
            throw DescriptionServiceError.missingSegment
        }
        return saved
    }

    private struct PreparedDescriptionInput: Sendable {
        let context: SegmentSearchContext
        let frames: [SegmentFrameRecord]
        let revision: String
        let inputVersion: String
    }

    /// Evidence and frames are committed atomically by the evidence lane. Reading
    /// the unique embedding revision before and after gives this multi-query read
    /// a stable snapshot without coupling either lane's lifecycle.
    private func prepareInput(
        segmentID: String,
        expectedRevision: String? = nil
    ) async throws -> PreparedDescriptionInput {
        guard let before = try await database.descriptionInputRevision(segmentID: segmentID) else {
            throw DescriptionServiceError.missingSegment
        }
        if let expectedRevision, before != expectedRevision {
            throw MediaDatabaseDerivationError.descriptionInputChanged
        }
        guard let context = try await database.searchContext(segmentID: segmentID) else {
            throw DescriptionServiceError.missingSegment
        }
        let frames = try await database.segmentFrames(segmentID: segmentID)
        guard !frames.isEmpty else { throw DescriptionServiceError.missingFrames }
        guard let after = try await database.descriptionInputRevision(segmentID: segmentID),
              before == after else {
            throw MediaDatabaseDerivationError.descriptionInputChanged
        }
        return PreparedDescriptionInput(
            context: context,
            frames: frames,
            revision: before,
            inputVersion: Self.inputVersion(
                context: context,
                frames: frames,
                modelID: configuration.description.derivationID
            )
        )
    }

    private func generate(_ input: PreparedDescriptionInput) async throws -> SegmentDescription {
        let kind = input.context.asset.mediaKind
        return try await sourceCache.withLocalURL(for: input.context.asset) { [self] sourceURL in
            let directory = workRoot
                .appending(path: "DescriptionRuns", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            // 图片直接解码原图；视频从源重新抽取代表帧。
            let extracted: [FrameSample]
            switch kind {
            case .image:
                extracted = [
                    try await FrameExtractor.extractImageAsset(
                        assetURL: sourceURL,
                        destinationDirectory: directory
                    )
                ]
            case .video:
                extracted = try await FrameExtractor.extractAtTimes(
                    assetURL: sourceURL,
                    timesMS: input.frames.map(\.timeMS),
                    destinationDirectory: directory
                )
            }
            let timedImages = extracted.map {
                TimedImageInput(timeMS: $0.timeMS, url: $0.imageURL)
            }
            // 图片没有时间轴：证据不带时间区间标签。
            let evidenceText: String
            switch kind {
            case .image:
                evidenceText = input.context.evidence.map { evidence in
                    let label = evidence.kind == .transcript ? "ASR" : "OCR"
                    return "[\(label)] \(evidence.text)"
                }.joined(separator: "\n")
            case .video:
                evidenceText = input.context.evidence.map { evidence in
                    let label = evidence.kind == .transcript ? "ASR" : "OCR"
                    return "[\(label) \(Self.format(evidence.startMS))–\(Self.format(evidence.endMS))] \(evidence.text)"
                }.joined(separator: "\n")
            }
            return try await runtime.describe(
                kind: kind,
                images: timedImages,
                evidenceText: evidenceText.isEmpty
                    ? (kind == .image ? "没有识别到 OCR 文本。" : "没有识别到 ASR 或 OCR 文本。")
                    : evidenceText
            )
        }
    }

    static func inputVersion(
        context: SegmentSearchContext,
        frames: [SegmentFrameRecord],
        modelID: String
    ) -> String {
        let source = [
            Self.promptVersion(for: context.asset.mediaKind),
            modelID,
            context.asset.fingerprint,
            frames.map { "\($0.timeMS):\($0.relativePath):\($0.perceptualHash)" }.joined(separator: "|"),
            context.evidence.map { "\($0.id):\($0.text)" }.joined(separator: "|")
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func format(_ milliseconds: Int64) -> String {
        String(format: "%.3fs", Double(milliseconds) / 1_000)
    }
}
