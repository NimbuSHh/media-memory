import Foundation

public actor SearchService {
    private static let literalWeight = 0.65
    private static let semanticWeight = 0.35
    private static let literalRankOffset = 8.0

    private let database: MediaDatabase
    private let configuration: ModelConfiguration
    private let runtime: LocalModelRuntime?
    /// 两种媒体类型的当前建库配方；语义索引同时装载两者。
    private let inputVersions: [String]
    private var cachedRevision: String?
    private var vectorIndex = SemanticVectorIndex(records: [])

    public init(
        database: MediaDatabase,
        configuration: ModelConfiguration,
        runtime: LocalModelRuntime? = nil
    ) {
        self.database = database
        self.configuration = configuration
        self.runtime = runtime
        inputVersions = [
            SegmentIndexer.inputVersion(for: configuration, kind: .video),
            SegmentIndexer.inputVersion(for: configuration, kind: .image)
        ]
    }

    /// Model-independent first phase. Callers can publish these results
    /// immediately while semantic enrichment waits for shared model resources.
    public func literalSearch(_ query: String, limit: Int = 20) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let snapshot = try await database.literalSearchSnapshot(
            query: trimmed,
            limit: candidateLimit(for: limit)
        )
        return try await assembleResults(
            literal: snapshot.matches,
            semanticBySegment: [:],
            limit: limit,
            snapshotContexts: snapshot.contexts
        )
    }

    public func search(_ query: String, limit: Int = 20) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let queryVector: EmbeddingVector?
        do {
            queryVector = try await semanticQueryVector(query: trimmed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            queryVector = nil
        }

        for _ in 0..<3 {
            let before = try await database.dataVersion()
            let snapshot = try await database.literalSearchSnapshot(
                query: trimmed,
                limit: candidateLimit(for: limit)
            )
            let semanticBySegment: [String: Double]
            if let queryVector {
                semanticBySegment = try await semanticMatches(
                    queryVector: queryVector,
                    candidateLimit: candidateLimit(for: limit)
                )
            } else {
                semanticBySegment = [:]
            }
            let results = try await assembleResults(
                literal: snapshot.matches,
                semanticBySegment: semanticBySegment,
                limit: limit
            )
            let after = try await database.dataVersion()
            if before == after { return results }
            cachedRevision = nil
        }

        // Continuous background commits should never produce a mixed result.
        // The already-fast literal path has its own single WAL snapshot.
        return try await literalSearch(trimmed, limit: limit)
    }

    private func assembleResults(
        literal: [LiteralSearchMatch],
        semanticBySegment: [String: Double],
        limit: Int,
        snapshotContexts: [String: SegmentSearchContext]? = nil
    ) async throws -> [SearchResult] {
        let literalGroups = Dictionary(grouping: literal, by: \.segmentID)
        var literalOrder: [String: Int] = [:]
        for match in literal where literalOrder[match.segmentID] == nil {
            literalOrder[match.segmentID] = literalOrder.count
        }
        var candidateIDs = Set(semanticBySegment.keys)
        candidateIDs.formUnion(literalGroups.keys)

        var results: [SearchResult] = []
        results.reserveCapacity(candidateIDs.count)
        for segmentID in candidateIDs {
            let context: SegmentSearchContext?
            if let snapshotContexts {
                context = snapshotContexts[segmentID]
            } else {
                context = try await database.searchContext(segmentID: segmentID)
            }
            guard let context else {
                continue
            }
            let literalMatches = literalGroups[segmentID] ?? []
            let literalScore = Self.literalRelevance(rank: literalOrder[segmentID])
            let semanticScore = semanticBySegment[segmentID]
            let bm25Score = literalMatches
                .map(\.rank)
                .filter { $0 < 0 }
                .map { -$0 }
                .max()
            let combinedScore = Self.combinedRelevance(
                literalScore: literalScore,
                semanticScore: semanticScore
            )
            let matchedEvidence = Self.oneEvidencePerSource(
                literalMatches.map(\.evidence)
            )
            let playbackStart: Int64
            let playbackEnd: Int64
            if let exact = matchedEvidence.first(where: { $0.kind != .visual })
                ?? matchedEvidence.first {
                playbackStart = exact.startMS
                playbackEnd = exact.endMS
            } else {
                playbackStart = context.segment.startMS
                playbackEnd = context.segment.endMS
            }
            results.append(
                SearchResult(
                    asset: context.asset,
                    segment: context.segment,
                    evidence: matchedEvidence,
                    literalScore: literalScore,
                    semanticScore: semanticScore,
                    bm25Score: bm25Score,
                    combinedScore: combinedScore,
                    matchedSegmentCount: 1,
                    visualDescriptionSegmentCount: literalMatches.contains {
                        $0.evidence.kind == .visual
                    } ? 1 : 0,
                    asrMatchCount: literalMatches.count {
                        $0.evidence.kind == .transcript
                    },
                    ocrMatchCount: literalMatches.count {
                        $0.evidence.kind == .ocr
                    },
                    playbackStartMS: playbackStart,
                    playbackEndMS: playbackEnd
                )
            )
        }

        results.sort { lhs, rhs in
            // 纯字面阶段必须保留 SQLite BM25 的候选顺序。之前所有字面
            // 命中都被压成同一个 1.0，导致这里退化成按路径和时间排序。
            if semanticBySegment.isEmpty {
                let lhsOrder = literalOrder[lhs.segment.id] ?? .max
                let rhsOrder = literalOrder[rhs.segment.id] ?? .max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            }
            if lhs.combinedScore == rhs.combinedScore {
                if lhs.asset.relativePath == rhs.asset.relativePath {
                    return lhs.segment.startMS < rhs.segment.startMS
                }
                return lhs.asset.relativePath.localizedStandardCompare(rhs.asset.relativePath)
                    == .orderedAscending
            }
            return lhs.combinedScore > rhs.combinedScore
        }
        // 检索和播放仍以片段为精确落点，但列表以视频为单位：同一视频
        // 只展示最高分片段，其余候选片段汇总为可解释统计。
        let groupedByAsset = Dictionary(grouping: results, by: \.asset.id)
        var emittedAssetIDs = Set<String>()
        var videoResults: [SearchResult] = []
        for best in results where emittedAssetIDs.insert(best.asset.id).inserted {
            let assetCandidates = groupedByAsset[best.asset.id] ?? [best]
            videoResults.append(
                SearchResult(
                    asset: best.asset,
                    segment: best.segment,
                    evidence: best.evidence,
                    literalScore: best.literalScore,
                    semanticScore: best.semanticScore,
                    bm25Score: best.bm25Score,
                    combinedScore: best.combinedScore,
                    matchedSegmentCount: assetCandidates.count,
                    visualDescriptionSegmentCount: assetCandidates.reduce(0) {
                        $0 + $1.visualDescriptionSegmentCount
                    },
                    asrMatchCount: assetCandidates.reduce(0) { $0 + $1.asrMatchCount },
                    ocrMatchCount: assetCandidates.reduce(0) { $0 + $1.ocrMatchCount },
                    playbackStartMS: best.playbackStartMS,
                    playbackEndMS: best.playbackEndMS
                )
            )
        }
        return Array(videoResults.prefix(max(1, limit)))
    }

    private func candidateLimit(for resultLimit: Int) -> Int {
        // 一个长视频可能贡献很多片段。扩大片段候选池后再按视频聚合，
        // 避免前几个长视频占满候选，导致不足 resultLimit 个视频。
        max(200, resultLimit * 20)
    }

    /// BM25 的绝对值受语料库与查询影响，不能直接与余弦分数相加。
    /// 使用带偏移的倒数名次把字面候选稳定映射到 0...1。
    nonisolated static func literalRelevance(rank: Int?) -> Double {
        guard let rank, rank >= 0 else { return 0 }
        return (literalRankOffset + 1) / (literalRankOffset + Double(rank) + 1)
    }

    nonisolated static func combinedRelevance(
        literalScore: Double,
        semanticScore: Double?
    ) -> Double {
        let boundedLiteral = min(1, max(0, literalScore))
        let boundedSemantic = min(1, max(0, semanticScore ?? 0))
        return boundedLiteral * literalWeight + boundedSemantic * semanticWeight
    }

    /// 结果卡片按来源解释“为什么命中”。同一来源即使命中多行也只展示
    /// 最相关的一条，避免上下文被误当成命中证据。
    nonisolated static func oneEvidencePerSource(
        _ evidence: [SearchEvidence]
    ) -> [SearchEvidence] {
        let groups = Dictionary(grouping: evidence, by: \.kind)
        return [SearchEvidenceKind.visual, .transcript, .ocr].compactMap {
            groups[$0]?.first
        }
    }

    private func semanticQueryVector(query: String) async throws -> EmbeddingVector? {
        guard let runtime else { return nil }
        return try await runtime.embedQuery(
            text: query,
            instruction: "Represent this text query for retrieving a matching video moment."
        )
    }

    private func semanticMatches(
        queryVector: EmbeddingVector,
        candidateLimit: Int
    ) async throws -> [String: Double] {
        try Task.checkCancellation()
        let revision = try await database.embeddingIndexRevision(
            modelID: configuration.embedding.derivationID,
            inputVersions: inputVersions
        )
        if revision != cachedRevision {
            let stored = try await database.storedEmbeddings(
                modelID: configuration.embedding.derivationID,
                inputVersions: inputVersions
            )
            vectorIndex = SemanticVectorIndex(records: stored)
            cachedRevision = revision
        }
        let candidates = vectorIndex.ranked(query: queryVector.values)
            .filter { $0.score > 0 }
            .prefix(candidateLimit)
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.segmentID, $0.score) })
    }
}
