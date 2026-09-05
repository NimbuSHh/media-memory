import Foundation
import MediaMemoryCore

/// 把媒体库混合检索暴露为 MCP 工具。输出同时携带人类可读的紧凑文本与
/// 结构化 JSON：文本面向 LLM 省 token，结构化内容供程序化消费。
public struct MediaMemorySearchBackend: MCPServerBackend {
    private let searchService: SearchService
    private let database: MediaDatabase
    /// embedding/描述模型摘要；语义检索不可用时为降级说明。
    private let modelSummary: String

    public init(searchService: SearchService, database: MediaDatabase, modelSummary: String) {
        self.searchService = searchService
        self.database = database
        self.modelSummary = modelSummary
    }

    public func tools() async -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "search_media",
                description: "在本地媒体库中检索视频与图片。支持自然语言语义描述与关键词，返回带时间戳的证据（画面描述/台词/画面文字），同一视频聚合为一条结果。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("自然语言或关键词，中英文均可")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .int(1),
                            "maximum": .int(25),
                            "default": .int(8)
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            MCPToolDefinition(
                name: "get_video_detail",
                description: "查看库内单个媒体的分段详情：每段的画面描述、台词与画面文字计数。path 为 search_media 返回的相对路径。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("媒体在库内的相对路径")
                        ]),
                        "includeTranscripts": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("是否附带台词原文")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ])
            ),
            MCPToolDefinition(
                name: "library_stats",
                description: "媒体库概览：资产数、片段数、向量数与当前模型配置。",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            )
        ]
    }

    public func call(name: String, arguments: JSONValue) async throws -> MCPToolOutcome {
        switch name {
        case "search_media":
            return try await searchMedia(arguments)
        case "get_video_detail":
            return try await videoDetail(arguments)
        case "library_stats":
            return try await libraryStats()
        default:
            throw MCPServerError.unknownTool(name)
        }
    }

    // MARK: - search_media

    private func searchMedia(_ arguments: JSONValue) async throws -> MCPToolOutcome {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw MCPServerError.invalidParams("query 必须是非空字符串")
        }
        let limit = Self.boundedInt(arguments["limit"], fallback: 8, range: 1...25)
        let results = try await searchService.search(query, limit: limit)

        guard !results.isEmpty else {
            return MCPToolOutcome(
                text: "没有命中「\(query)」。可尝试换一种描述（画面内容、台词、画面文字）。",
                structuredContent: .object(["query": .string(query), "count": .int(0), "results": .array([])])
            )
        }

        var lines: [String] = ["共 \(results.count) 个媒体命中："]
        var structuredResults: [JSONValue] = []
        for (index, result) in results.enumerated() {
            lines.append(
                Self.resultLine(index: index + 1, result: result)
            )
            for evidence in result.evidence {
                lines.append("  \(Self.kindLabel(evidence.kind)): \(Self.snippet(evidence.text))")
            }
            lines.append("  路径: \(result.asset.relativePath)")
            structuredResults.append(Self.structuredResult(result))
        }
        return MCPToolOutcome(
            text: lines.joined(separator: "\n"),
            structuredContent: .object([
                "query": .string(query),
                "count": .int(Int64(results.count)),
                "results": .array(structuredResults)
            ])
        )
    }

    private static func resultLine(index: Int, result: SearchResult) -> String {
        var parts = [
            "\(index). [\(Self.score(result.combinedScore))] \(result.asset.filename)"
        ]
        if result.asset.hasTimeline {
            parts.append(
                "\(Self.timecode(result.playbackStartMS))–\(Self.timecode(result.playbackEndMS))"
            )
        }
        parts.append("命中 \(result.matchedSegmentCount) 段")
        return parts.joined(separator: " · ")
    }

    private static func structuredResult(_ result: SearchResult) -> JSONValue {
        var value: [String: JSONValue] = [
            "path": .string(result.asset.relativePath),
            "name": .string(result.asset.filename),
            "mediaKind": .string(result.asset.mediaKind.rawValue),
            "hasTimeline": .bool(result.asset.hasTimeline),
            "startMS": .int(result.segment.startMS),
            "endMS": .int(result.segment.endMS),
            "playbackStartMS": .int(result.playbackStartMS),
            "playbackEndMS": .int(result.playbackEndMS),
            "combinedScore": .double(result.combinedScore),
            "literalScore": .double(result.literalScore),
            "semanticScore": result.semanticScore.map(JSONValue.double) ?? .null,
            "bm25Score": result.bm25Score.map(JSONValue.double) ?? .null,
            "matchedSegmentCount": .int(Int64(result.matchedSegmentCount)),
            "evidence": .array(result.evidence.map(Self.structuredEvidence))
        ]
        if !result.asset.hasTimeline {
            value.removeValue(forKey: "startMS")
            value.removeValue(forKey: "endMS")
        }
        return .object(value)
    }

    private static func structuredEvidence(_ evidence: SearchEvidence) -> JSONValue {
        .object([
            "kind": .string(evidence.kind.rawValue),
            "text": .string(Self.snippet(evidence.text)),
            "startMS": .int(evidence.startMS),
            "endMS": .int(evidence.endMS)
        ])
    }

    // MARK: - get_video_detail

    private func videoDetail(_ arguments: JSONValue) async throws -> MCPToolOutcome {
        guard let path = arguments["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw MCPServerError.invalidParams("path 必须是非空字符串")
        }
        let includeTranscripts = (arguments["includeTranscripts"]?.boolValue ?? false)
        guard let asset = try await resolveAsset(path: path) else {
            return MCPToolOutcome(
                text: "库内没有找到「\(path)」。请使用 search_media 返回的相对路径。",
                isError: true
            )
        }

        let detail = try await database.assetLibraryDetail(assetID: asset.id)
        let descriptions = try await database.latestDescriptions(assetID: asset.id)

        var kindDescription = "视频"
        var durationDescription = ""
        if !asset.hasTimeline {
            kindDescription = "图片"
        } else {
            durationDescription = " · 时长 \(Self.timecode(asset.durationMS))"
        }

        var lines = [
            "\(asset.relativePath) · \(kindDescription)\(durationDescription) · \(detail.segments.count) 段（已建库 \(detail.indexedSegmentCount)）"
        ]
        var structuredSegments: [JSONValue] = []

        for (index, segment) in detail.segments.enumerated() {
            var line = "  \(index + 1)"
            if asset.hasTimeline {
                line += " \(Self.timecode(segment.segment.startMS))–\(Self.timecode(segment.segment.endMS))"
            }
            if !segment.isIndexed {
                line += " · 未建库"
            }
            let ocrCount = detail.ocrBySegment[segment.segment.id]?.count ?? 0
            if ocrCount > 0 {
                line += " · 字幕×\(ocrCount)"
            }
            lines.append(line)
            if let description = descriptions[segment.segment.id]?.description {
                lines.append("      \(Self.snippet(description.summary, maxLength: 200))")
                for extra in description.visibleDetails.prefix(2) {
                    lines.append("      \(Self.snippet(extra, maxLength: 160))")
                }
            }
            if includeTranscripts {
                for transcript in detail.transcriptsBySegment[segment.segment.id]?.prefix(3) ?? [] {
                    lines.append("      台词: \(Self.snippet(transcript.text))")
                }
            }
            structuredSegments.append(Self.structuredSegment(segment, descriptions: descriptions, detail: detail))
        }

        return MCPToolOutcome(
            text: lines.joined(separator: "\n"),
            structuredContent: .object([
                "path": .string(asset.relativePath),
                "name": .string(asset.filename),
                "mediaKind": .string(asset.mediaKind.rawValue),
                "hasTimeline": .bool(asset.hasTimeline),
                "durationMS": asset.hasTimeline ? .int(asset.durationMS) : .null,
                "segmentCount": .int(Int64(detail.segments.count)),
                "indexedSegmentCount": .int(Int64(detail.indexedSegmentCount)),
                "segments": .array(structuredSegments)
            ])
        )
    }

    private func resolveAsset(path: String) async throws -> MediaAssetRecord? {
        if let exact = try await database.asset(relativePath: path) {
            return exact
        }
        // 兼容不带目录前缀的文件名引用。
        let all = try await database.mediaAssets()
        let query = path.lowercased()
        return all.first { asset in
            let relative = asset.relativePath.lowercased()
            return relative == query || relative.hasSuffix("/" + query)
        }
    }

    private static func structuredSegment(
        _ segment: AssetSegmentInfo,
        descriptions: [String: CachedSegmentDescription],
        detail: AssetLibraryDetail
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "segmentID": .string(segment.segment.id),
            "ordinal": .int(Int64(segment.segment.ordinal)),
            "isIndexed": .bool(segment.isIndexed)
        ]
        if segment.segment.endMS > segment.segment.startMS {
            value["startMS"] = .int(segment.segment.startMS)
            value["endMS"] = .int(segment.segment.endMS)
        }
        if let description = descriptions[segment.segment.id]?.description {
            value["description"] = .object([
                "summary": .string(description.summary),
                "visibleDetails": .array(description.visibleDetails.map { .string($0) })
            ])
        }
        let transcripts = detail.transcriptsBySegment[segment.segment.id] ?? []
        value["transcripts"] = .array(transcripts.map {
            .object([
                "text": .string($0.text),
                "startMS": .int($0.startMS),
                "endMS": .int($0.endMS)
            ])
        })
        value["ocrCount"] = .int(Int64(detail.ocrBySegment[segment.segment.id]?.count ?? 0))
        return .object(value)
    }

    // MARK: - library_stats

    private func libraryStats() async throws -> MCPToolOutcome {
        let statistics = try await database.libraryStatistics()
        let roots = try await database.libraryRoots()
        let queueStates = try await database.libraryRootQueueStates()
        let ordered = LibraryRootQueue.orderedRoots(roots: roots, states: queueStates)

        var lines = [
            "资产 \(statistics.assetCount) · 活动段 \(statistics.segmentCount) · 向量 \(statistics.embeddingCount)",
            "模型: \(modelSummary)"
        ]
        if !ordered.isEmpty {
            // 展示顺序即处理顺序：排队中的库按调度顺序在前，已完成按完成时刻倒序。
            lines.append("处理队列（从前到后）：")
            for (index, root) in ordered.enumerated() {
                let state = queueStates[root.id]
                if !LibraryRootQueue.isProcessed(root, states: queueStates) {
                    let note = root.lastScanAt == nil
                        ? "等待首次扫描"
                        : "待处理任务 \(state?.pendingJobCount ?? 0)"
                    lines.append("  \(index + 1). \(root.name) · 排队中（\(note)）")
                } else if let completedAt = state?.lastJobActivityAt {
                    lines.append("  \(root.name) · 已完成（\(completedAt.formatted(date: .abbreviated, time: .shortened))）")
                } else {
                    lines.append("  \(root.name) · 已完成")
                }
            }
        }

        var structured: [String: JSONValue] = [
            "assetCount": .int(Int64(statistics.assetCount)),
            "segmentCount": .int(Int64(statistics.segmentCount)),
            "embeddingCount": .int(Int64(statistics.embeddingCount)),
            "modelSummary": .string(modelSummary)
        ]
        structured["queue"] = .array(ordered.map { root in
            var entry: [String: JSONValue] = [
                "name": .string(root.name),
                "path": .string(root.path),
                "processingRank": .int(Int64(root.processingRank)),
                "pendingJobs": .int(Int64(queueStates[root.id]?.pendingJobCount ?? 0)),
                "isProcessed": .bool(LibraryRootQueue.isProcessed(root, states: queueStates))
            ]
            if let activity = queueStates[root.id]?.lastJobActivityAt {
                entry["lastJobActivityAt"] = .string(activity.formatted(.iso8601))
            }
            return .object(entry)
        })

        return MCPToolOutcome(
            text: lines.joined(separator: "\n"),
            structuredContent: .object(structured)
        )
    }

    // MARK: - Formatting

    private static func kindLabel(_ kind: SearchEvidenceKind) -> String {
        switch kind {
        case .visual: "画面"
        case .transcript: "台词"
        case .ocr: "字幕"
        }
    }

    private static func timecode(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func score(_ value: Double) -> String {
        String(format: "%.2f", min(1, max(0, value)))
    }

    private static func snippet(_ text: String, maxLength: Int = 140) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength)) + "…"
    }

    private static func boundedInt(_ value: JSONValue?, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let raw = value?.intValue, let parsed = Int(exactly: raw) else { return fallback }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }
}

private extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
