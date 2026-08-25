/// A signal that a semantic segment may end at a source-timeline position.
public enum SemanticBoundarySource: String, CaseIterable, Hashable, Sendable {
    case shotChange
    case sentenceEnd
    case pause
    case ocrChange
}

/// One boundary observation. Scores are normalized to `0...1` by the planner.
/// Sentence and pause observations can normally use the default score; shot and
/// OCR detectors should pass their measured confidence.
public struct SemanticBoundaryCandidate: Equatable, Sendable {
    public let timeMS: Int64
    public let source: SemanticBoundarySource
    public let score: Double

    public init(
        timeMS: Int64,
        source: SemanticBoundarySource,
        score: Double = 1
    ) {
        self.timeMS = timeMS
        self.source = source
        self.score = score
    }
}

public struct SemanticSegmentationInput: Equatable, Sendable {
    public let durationMS: Int64
    public let boundaryCandidates: [SemanticBoundaryCandidate]

    public init(
        durationMS: Int64,
        boundaryCandidates: [SemanticBoundaryCandidate]
    ) {
        self.durationMS = durationMS
        self.boundaryCandidates = boundaryCandidates
    }
}

/// A deterministic, non-overlapping range on the original media timeline.
public struct PlannedSemanticSegment: Equatable, Sendable {
    public let ordinal: Int
    public let startMS: Int64
    public let endMS: Int64
    /// Signals merged at `endMS`. Empty means that the end is either the end of
    /// the video or a synthetic boundary needed to enforce the hard maximum.
    public let endBoundarySources: [SemanticBoundarySource]

    public init(
        ordinal: Int,
        startMS: Int64,
        endMS: Int64,
        endBoundarySources: [SemanticBoundarySource]
    ) {
        self.ordinal = ordinal
        self.startMS = startMS
        self.endMS = endMS
        self.endBoundarySources = endBoundarySources
    }
}

/// Selects semantic segment boundaries without reading media or mutating state.
///
/// Minimum and target durations are soft around strong content boundaries. The
/// minimum is enforced whenever the whole video is long enough, while the hard
/// maximum is always enforced. Candidate order never affects the result.
public struct SemanticSegmentPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let minimumDurationMS: Int64
        public let targetMinimumDurationMS: Int64
        public let targetMaximumDurationMS: Int64
        public let hardMaximumDurationMS: Int64
        public let boundaryMergeToleranceMS: Int64
        public let minimumBoundaryStrength: Double

        public init(
            minimumDurationMS: Int64 = 4_000,
            targetMinimumDurationMS: Int64 = 8_000,
            targetMaximumDurationMS: Int64 = 15_000,
            hardMaximumDurationMS: Int64 = 30_000,
            boundaryMergeToleranceMS: Int64 = 300,
            minimumBoundaryStrength: Double = 0.2
        ) {
            precondition(minimumDurationMS > 0)
            precondition(targetMinimumDurationMS >= minimumDurationMS)
            precondition(targetMaximumDurationMS >= targetMinimumDurationMS)
            precondition(hardMaximumDurationMS >= targetMaximumDurationMS)
            precondition(boundaryMergeToleranceMS >= 0)
            precondition(minimumBoundaryStrength >= 0)

            self.minimumDurationMS = minimumDurationMS
            self.targetMinimumDurationMS = targetMinimumDurationMS
            self.targetMaximumDurationMS = targetMaximumDurationMS
            self.hardMaximumDurationMS = hardMaximumDurationMS
            self.boundaryMergeToleranceMS = boundaryMergeToleranceMS
            self.minimumBoundaryStrength = minimumBoundaryStrength
        }
    }

    private struct MergedBoundary {
        let timeMS: Int64
        let sources: [SemanticBoundarySource]
        let strength: Double
    }

    private let configuration: Configuration

    public var effectiveConfiguration: Configuration { configuration }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func plan(_ input: SemanticSegmentationInput) -> [PlannedSemanticSegment] {
        guard input.durationMS > 0 else { return [] }

        let boundaries = mergedBoundaries(
            from: input.boundaryCandidates,
            durationMS: input.durationMS
        )
        var result: [PlannedSemanticSegment] = []
        var startMS: Int64 = 0
        var boundarySearchStartIndex = 0

        while startMS < input.durationMS {
            let remainingMS = input.durationMS - startMS
            let endMS: Int64
            let sources: [SemanticBoundarySource]

            if remainingMS <= configuration.targetMaximumDurationMS {
                // The remainder already fits the target range. Cutting it again
                // would turn dense shot candidates into a series of tiny clips.
                endMS = input.durationMS
                sources = []
            } else if remainingMS < configuration.minimumDurationMS * 2 {
                // A split would create at least one sub-minimum segment. This
                // also makes a short video one complete searchable unit.
                endMS = input.durationMS
                sources = []
            } else if let boundary = bestBoundary(
                after: startMS,
                durationMS: input.durationMS,
                boundaries: boundaries,
                searchStartIndex: &boundarySearchStartIndex
            ) {
                endMS = boundary.timeMS
                sources = boundary.sources
            } else if remainingMS <= configuration.hardMaximumDurationMS {
                endMS = input.durationMS
                sources = []
            } else {
                endMS = fallbackBoundary(after: startMS, durationMS: input.durationMS)
                sources = []
            }

            // `bestBoundary` and `fallbackBoundary` both make progress. Keep a
            // defensive fallback here so malformed custom configurations can
            // never turn planning into an infinite loop.
            let safeEndMS = min(input.durationMS, max(startMS + 1, endMS))
            result.append(
                PlannedSemanticSegment(
                    ordinal: result.count,
                    startMS: startMS,
                    endMS: safeEndMS,
                    endBoundarySources: sources
                )
            )
            startMS = safeEndMS
        }

        return result
    }

    private func bestBoundary(
        after startMS: Int64,
        durationMS: Int64,
        boundaries: [MergedBoundary],
        searchStartIndex: inout Int
    ) -> MergedBoundary? {
        let earliest = startMS + configuration.minimumDurationMS
        let latestByLength = startMS + min(
            configuration.hardMaximumDurationMS,
            durationMS - startMS
        )
        let latestLeavingValidTail = durationMS - configuration.minimumDurationMS
        let latest = min(latestByLength, latestLeavingValidTail)
        guard earliest <= latest else { return nil }

        while searchStartIndex < boundaries.count,
              boundaries[searchStartIndex].timeMS < earliest {
            searchStartIndex += 1
        }

        var best: MergedBoundary?
        var index = searchStartIndex
        while index < boundaries.count {
            let boundary = boundaries[index]
            if boundary.timeMS > latest { break }
            if boundary.strength >= configuration.minimumBoundaryStrength,
               isPreferred(boundary, over: best, after: startMS) {
                best = boundary
            }
            index += 1
        }
        return best
    }

    private func isPreferred(
        _ candidate: MergedBoundary,
        over current: MergedBoundary?,
        after startMS: Int64
    ) -> Bool {
        guard let current else { return true }
        let candidateRank = boundaryRank(candidate, after: startMS)
        let currentRank = boundaryRank(current, after: startMS)
        if candidateRank != currentRank { return candidateRank > currentRank }
        if candidate.strength != current.strength {
            return candidate.strength > current.strength
        }
        // Prefer the earlier time for otherwise identical observations.
        return candidate.timeMS < current.timeMS
    }

    private func boundaryRank(_ boundary: MergedBoundary, after startMS: Int64) -> Double {
        let segmentDurationMS = boundary.timeMS - startMS
        // Content evidence dominates. The small duration bonus only resolves
        // similar candidates in favor of the 8-15 second target range.
        return boundary.strength + durationAffinity(segmentDurationMS) * 0.35
    }

    private func durationAffinity(_ durationMS: Int64) -> Double {
        let duration = Double(durationMS)
        let minimum = Double(configuration.minimumDurationMS)
        let targetMinimum = Double(configuration.targetMinimumDurationMS)
        let targetMaximum = Double(configuration.targetMaximumDurationMS)
        let hardMaximum = Double(configuration.hardMaximumDurationMS)

        if duration < targetMinimum {
            let range = max(1, targetMinimum - minimum)
            return 0.7 * max(0, duration - minimum) / range
        }
        if duration <= targetMaximum {
            let midpoint = (targetMinimum + targetMaximum) / 2
            let halfRange = max(1, (targetMaximum - targetMinimum) / 2)
            return 1 - 0.3 * abs(duration - midpoint) / halfRange
        }

        let range = max(1, hardMaximum - targetMaximum)
        return 0.7 * max(0, hardMaximum - duration) / range
    }

    private func fallbackBoundary(after startMS: Int64, durationMS: Int64) -> Int64 {
        let remainingMS = durationMS - startMS
        let tailAfterMaximum = remainingMS - configuration.hardMaximumDurationMS

        // Avoid a 30s + tiny-tail shape when no semantic evidence exists. Two
        // balanced ranges are more useful and still obey the hard maximum.
        if tailAfterMaximum > 0,
           tailAfterMaximum < configuration.targetMinimumDurationMS {
            return startMS + remainingMS / 2
        }
        return startMS + configuration.hardMaximumDurationMS
    }

    private func mergedBoundaries(
        from candidates: [SemanticBoundaryCandidate],
        durationMS: Int64
    ) -> [MergedBoundary] {
        let sorted = candidates
            .filter { $0.timeMS > 0 && $0.timeMS < durationMS && $0.score.isFinite }
            .map {
                SemanticBoundaryCandidate(
                    timeMS: $0.timeMS,
                    source: $0.source,
                    score: min(1, max(0, $0.score))
                )
            }
            .sorted {
                if $0.timeMS != $1.timeMS { return $0.timeMS < $1.timeMS }
                let lhsPriority = sourcePriority($0.source)
                let rhsPriority = sourcePriority($1.source)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return $0.score > $1.score
            }

        var result: [MergedBoundary] = []
        var cluster: [SemanticBoundaryCandidate] = []
        var clusterStartMS: Int64?

        for candidate in sorted {
            if let existingClusterStartMS = clusterStartMS,
               candidate.timeMS - existingClusterStartMS > configuration.boundaryMergeToleranceMS {
                result.append(merge(cluster))
                cluster = []
                clusterStartMS = candidate.timeMS
            } else if clusterStartMS == nil {
                clusterStartMS = candidate.timeMS
            }
            cluster.append(candidate)
        }
        if !cluster.isEmpty {
            result.append(merge(cluster))
        }
        return result
    }

    private func merge(_ cluster: [SemanticBoundaryCandidate]) -> MergedBoundary {
        var bestBySource: [SemanticBoundarySource: SemanticBoundaryCandidate] = [:]
        for candidate in cluster {
            if let existing = bestBySource[candidate.source] {
                if candidate.score > existing.score
                    || (candidate.score == existing.score && candidate.timeMS < existing.timeMS) {
                    bestBySource[candidate.source] = candidate
                }
            } else {
                bestBySource[candidate.source] = candidate
            }
        }

        let contributors = bestBySource.values.sorted {
            let lhsValue = weightedScore($0)
            let rhsValue = weightedScore($1)
            if lhsValue != rhsValue { return lhsValue > rhsValue }
            let lhsPriority = sourcePriority($0.source)
            let rhsPriority = sourcePriority($1.source)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return $0.timeMS < $1.timeMS
        }
        let representative = contributors[0]
        let sources = contributors.map(\.source).sorted {
            sourcePriority($0) < sourcePriority($1)
        }

        return MergedBoundary(
            timeMS: representative.timeMS,
            sources: sources,
            strength: contributors.reduce(0) { $0 + weightedScore($1) }
        )
    }

    private func weightedScore(_ candidate: SemanticBoundaryCandidate) -> Double {
        let sourceWeight: Double = switch candidate.source {
        case .shotChange: 1
        case .sentenceEnd: 0.9
        case .pause: 0.75
        case .ocrChange: 0.65
        }
        return candidate.score * sourceWeight
    }

    private func sourcePriority(_ source: SemanticBoundarySource) -> Int {
        switch source {
        case .shotChange: 0
        case .sentenceEnd: 1
        case .pause: 2
        case .ocrChange: 3
        }
    }
}
