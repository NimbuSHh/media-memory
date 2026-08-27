import CryptoKit
import Foundation

public struct SegmentationEvent: Equatable, Sendable {
    public let assetID: String
    public let assetName: String
    public let stage: String
    public let progress: IndexingProgress

    public init(
        assetID: String,
        assetName: String,
        stage: String,
        progress: IndexingProgress
    ) {
        self.assetID = assetID
        self.assetName = assetName
        self.stage = stage
        self.progress = progress
    }
}

public enum ContentSegmenterError: Error, LocalizedError, Sendable {
    case sourceChanged
    case noSegments

    public var errorDescription: String? {
        switch self {
        case .sourceChanged:
            "源视频在分片分析期间发生变化。"
        case .noSegments:
            "没有生成可用的语义片段。"
        }
    }
}

/// Produces content-aware segment generations without modifying source media.
///
/// This is deliberately independent from ASR/OCR/model services: it is a fast
/// producer lane. Its output is staged beside the active generation, indexed by
/// the existing evidence pipeline, and switched live only after all staged
/// segments have embeddings.
public actor ContentSegmenter {
    public typealias EventHandler = @Sendable (SegmentationEvent) async -> Void
    public typealias FeatureExtractor = @Sendable (
        URL,
        TimelineFeatureExtractionConfiguration
    ) async throws -> TimelineFeatureExtractionResult

    public static let algorithmFamily = "semantic-v2-visual-silence-v2"

    private let database: MediaDatabase
    private let sourceCache: LocalSourceCache
    private let featureConfiguration: TimelineFeatureExtractionConfiguration
    private let planner: SemanticSegmentPlanner
    private let extractFeatures: FeatureExtractor
    private let algorithmVersion: String
    private let parametersJSON: String

    public init(
        database: MediaDatabase,
        sourceCache: LocalSourceCache,
        featureConfiguration: TimelineFeatureExtractionConfiguration = .init(),
        planner: SemanticSegmentPlanner = .init(),
        extractFeatures: @escaping FeatureExtractor = { url, configuration in
            try await TimelineFeatureExtractor.extract(
                assetURL: url,
                configuration: configuration
            )
        }
    ) {
        let effectiveConfiguration = TimelineFeatureExtractor.normalizedConfiguration(
            featureConfiguration
        )
        self.database = database
        self.sourceCache = sourceCache
        self.featureConfiguration = effectiveConfiguration
        self.planner = planner
        self.extractFeatures = extractFeatures
        let parameterValues = Self.parameterValues(
            featureConfiguration: effectiveConfiguration,
            plannerConfiguration: planner.effectiveConfiguration
        )
        let canonicalData = try? JSONSerialization.data(
            withJSONObject: parameterValues,
            options: [.sortedKeys]
        )
        let digest = SHA256.hash(data: canonicalData ?? Data())
            .map { String(format: "%02x", $0) }
            .joined()
        let version = "\(Self.algorithmFamily)-\(digest.prefix(12))"
        algorithmVersion = version
        parametersJSON = Self.makeParametersJSON(
            values: parameterValues,
            algorithmVersion: version
        )
    }

    public func prepareQueue() async throws -> IndexingProgress {
        try await database.reconcileSegmentationJobs(
            algorithmVersion: algorithmVersion
        )
    }

    public func retryFailed() async throws -> IndexingProgress {
        try await database.retryFailedJobs(kind: .segmentAsset)
        return try await database.segmentationProgress()
    }

    public func progress() async throws -> IndexingProgress {
        try await database.segmentationProgress()
    }

    public func runUntilIdle(
        onEvent: EventHandler? = nil,
        onSourceUnavailable: SourceUnavailableHandler? = nil
    ) async throws -> IndexRunSummary {
        _ = try await prepareQueue()
        var succeeded = 0
        var failed = 0

        laneLoop: while !Task.isCancelled {
            let target: AssetSegmentationTarget
            let cachedAssetID = await sourceCache.cachedAssetID()
            switch try await database.claimNextSegmentationJob(
                restrictToAssetID: cachedAssetID
            ) {
            case let .target(value):
                target = value
            case .idle:
                break laneLoop
            }

            do {
                try await sourceCache.withLocalURL(for: target.asset) { [self] _ in
                    try await process(target: target, onEvent: onEvent)
                }
                succeeded += 1
            } catch is CancellationError {
                try? await database.returnSegmentationJobToQueue(
                    claim: target.job.claimToken
                )
                throw CancellationError()
            } catch let unavailable as SourceUnavailableError {
                // 通知必须 await：断路状态要先于车道收尾落地，否则收尾的
                // 重启逻辑会在断路生效前把车道再拉起一次。
                switch await resolveSourceDisposition(onSourceUnavailable, unavailable) {
                case .park:
                    try? await database.returnSegmentationJobToQueue(
                        claim: target.job.claimToken,
                        stage: "source_unavailable"
                    )
                    break laneLoop
                case .failJob:
                    do {
                        try await database.failSegmentationJob(
                            claim: target.job.claimToken,
                            message: unavailable.localizedDescription
                        )
                        failed += 1
                        await publish(target: target, stage: "failed", onEvent: onEvent)
                    } catch SegmentationDatabaseError.staleClaim {
                        // 新一轮认领已接管该任务。
                    }
                    continue laneLoop
                }
            } catch SegmentationDatabaseError.staleClaim {
                continue
            } catch {
                let isAvailable = try await database.isIndexTargetAvailable(
                    assetID: target.asset.id,
                    sourceFingerprint: target.asset.fingerprint
                )
                if !isAvailable {
                    try? await database.returnSegmentationJobToQueue(
                        claim: target.job.claimToken,
                        stage: "target_unavailable"
                    )
                } else {
                    do {
                        try await database.failSegmentationJob(
                            claim: target.job.claimToken,
                            message: error.localizedDescription
                        )
                        failed += 1
                        await publish(target: target, stage: "failed", onEvent: onEvent)
                    } catch SegmentationDatabaseError.staleClaim {
                        continue
                    }
                }
            }
        }
        try Task.checkCancellation()
        return IndexRunSummary(succeeded: succeeded, failed: failed)
    }

    private func process(
        target: AssetSegmentationTarget,
        onEvent: EventHandler?
    ) async throws {
        try await stage("analyzing", target: target, onEvent: onEvent)
        let features = try await AsyncTimeout.run(
            for: analysisTimeout(durationMS: target.asset.durationMS),
            operationName: "分析视频分片边界"
        ) { [sourceCache, featureConfiguration, extractFeatures] in
            try await sourceCache.withLocalURL(for: target.asset) { sourceURL in
                try await extractFeatures(sourceURL, featureConfiguration)
            }
        }
        try Task.checkCancellation()

        try await stage("planning", target: target, onEvent: onEvent)
        let candidates = features.candidates.compactMap(Self.boundaryCandidate)
        let observations = features.candidates.map(Self.boundaryObservation)
        // 时长交叉验证：解码得到的 PTS 时长是比容器探测更强的证据。
        // 候选与解码一致 → 证实漂移；解码与权威值一致 → 候选是探测误报，
        // 放弃修正、保留现有代际；两者都不同 → 以解码时长为准。
        let authoritativeDurationMS = target.asset.durationMS
        let plannedDurationMS: Int64
        var confirmedCandidateMS: Int64?
        if let candidateMS = target.candidateDurationMS {
            let decodedMS = features.durationMS
            if abs(decodedMS - candidateMS) <= TimelineDriftPolicy.toleranceMS {
                plannedDurationMS = candidateMS
                confirmedCandidateMS = candidateMS
            } else if abs(decodedMS - authoritativeDurationMS) <= TimelineDriftPolicy.toleranceMS {
                try await database.dismissSegmentationDurationCandidate(
                    claim: target.job.claimToken
                )
                await publish(target: target, stage: "complete", onEvent: onEvent)
                return
            } else {
                plannedDurationMS = decodedMS
                confirmedCandidateMS = decodedMS
            }
        } else {
            plannedDurationMS = authoritativeDurationMS
        }
        let planned = planner.plan(
            SemanticSegmentationInput(
                // The staged coverage bound. Detector PTS values are clamped
                // by the planner.
                durationMS: plannedDurationMS,
                boundaryCandidates: candidates
            )
        )
        guard !planned.isEmpty else { throw ContentSegmenterError.noSegments }
        let drafts = planned.map {
            SemanticSegmentDraft(startMS: $0.startMS, endMS: $0.endMS)
        }

        try await stage("committing", target: target, onEvent: onEvent)
        try await database.commitSegmentation(
            claim: target.job.claimToken,
            assetID: target.asset.id,
            sourceFingerprint: target.asset.fingerprint,
            algorithmVersion: algorithmVersion,
            parametersJSON: parametersJSON,
            segments: drafts,
            observations: observations,
            candidateDurationMS: confirmedCandidateMS
        )
        await publish(target: target, stage: "complete", onEvent: onEvent)
    }

    private func stage(
        _ value: String,
        target: AssetSegmentationTarget,
        onEvent: EventHandler?
    ) async throws {
        try Task.checkCancellation()
        try await database.updateSegmentationJob(
            claim: target.job.claimToken,
            stage: value
        )
        await publish(target: target, stage: value, onEvent: onEvent)
    }

    private func publish(
        target: AssetSegmentationTarget,
        stage: String,
        onEvent: EventHandler?
    ) async {
        guard let onEvent, let progress = try? await database.segmentationProgress() else {
            return
        }
        await onEvent(
            SegmentationEvent(
                assetID: target.asset.id,
                assetName: target.asset.filename,
                stage: stage,
                progress: progress
            )
        )
    }

    private func analysisTimeout(durationMS: Int64) -> Duration {
        // Remote volumes can be much slower than local disks. Bound hangs while
        // scaling enough for long media: 10 minutes minimum, 2 hours maximum.
        let sourceSeconds = max(0, durationMS / 1_000)
        let timeoutSeconds = min(7_200, max(600, sourceSeconds / 2 + 300))
        return .seconds(timeoutSeconds)
    }

    private static func boundaryCandidate(
        _ feature: TimelineFeatureCandidate
    ) -> SemanticBoundaryCandidate? {
        switch feature.evidence {
        case let .visualChange(score, _):
            return SemanticBoundaryCandidate(
                timeMS: feature.timeMS,
                source: .shotChange,
                score: min(1, max(0, score))
            )
        case let .silenceEnd(_, durationMS):
            // Longer pauses are stronger, but even the configured minimum is a
            // useful secondary signal when no visual cut exists.
            let score = min(1, max(0.35, Double(durationMS) / 1_500))
            return SemanticBoundaryCandidate(
                timeMS: feature.timeMS,
                source: .pause,
                score: score
            )
        }
    }

    private static func boundaryObservation(
        _ feature: TimelineFeatureCandidate
    ) -> TimelineBoundaryObservationDraft {
        switch feature.evidence {
        case let .visualChange(score, previousSampleTimeMS):
            return TimelineBoundaryObservationDraft(
                timeMS: feature.timeMS,
                kind: .visualChange,
                score: min(1, max(0, score)),
                detailsJSON: jsonString([
                    "previous_sample_time_ms": previousSampleTimeMS
                ])
            )
        case let .silenceEnd(startTimeMS, durationMS):
            return TimelineBoundaryObservationDraft(
                timeMS: feature.timeMS,
                kind: .silenceEnd,
                score: min(1, max(0.35, Double(durationMS) / 1_500)),
                detailsJSON: jsonString([
                    "duration_ms": durationMS,
                    "start_time_ms": startTimeMS
                ])
            )
        }
    }

    private static func jsonString(_ value: [String: Int64]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parameterValues(
        featureConfiguration configuration: TimelineFeatureExtractionConfiguration,
        plannerConfiguration planner: SemanticSegmentPlanner.Configuration
    ) -> [String: Any] {
        [
            "analysis_height": configuration.analysisHeight,
            "analysis_width": configuration.analysisWidth,
            "audio_window_ms": configuration.audioAnalysisWindowMS,
            "minimum_silence_ms": configuration.minimumSilenceDurationMS,
            "silence_threshold_dbfs": configuration.silenceThresholdDBFS,
            "visual_candidate_spacing_ms": configuration.minimumVisualCandidateSpacingMS,
            "visual_change_threshold": configuration.visualChangeThreshold,
            "visual_sample_interval_ms": configuration.visualSampleIntervalMS,
            "maximum_visual_sample_count": configuration.maximumVisualSampleCount,
            "visual_request_batch_size": configuration.visualRequestBatchSize,
            "planner_minimum_duration_ms": planner.minimumDurationMS,
            "planner_target_minimum_duration_ms": planner.targetMinimumDurationMS,
            "planner_target_maximum_duration_ms": planner.targetMaximumDurationMS,
            "planner_hard_maximum_duration_ms": planner.hardMaximumDurationMS,
            "planner_boundary_merge_tolerance_ms": planner.boundaryMergeToleranceMS,
            "planner_minimum_boundary_strength": planner.minimumBoundaryStrength
        ]
    }

    private static func makeParametersJSON(
        values: [String: Any],
        algorithmVersion: String
    ) -> String {
        var values = values
        values["algorithm_version"] = algorithmVersion
        guard let data = try? JSONSerialization.data(
            withJSONObject: values,
            options: [.sortedKeys]
        ) else { return "{\"algorithm_version\":\"\(algorithmVersion)\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}
