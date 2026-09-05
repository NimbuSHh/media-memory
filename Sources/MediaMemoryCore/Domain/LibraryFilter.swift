import Foundation

/// 以媒体为单位的处理进度分类。底部队列总览、侧栏路径统计与媒体列表
/// 筛选共用同一份实现——同一资产在所有入口必须归入同一桶，任何一处
/// 需要新口径时只改这里。
public enum AssetProcessingBucket: String, CaseIterable, Sendable {
    /// 任一车道正在执行。
    case inProgress
    /// 有待执行任务，或车道空闲但产物不完整（等 reconcile 补齐）。
    case waiting
    /// 任一任务失败或被取消。
    case failed
    /// 建库与描述产物覆盖全部片段。
    case completed
    /// 从未入队（无任何片段与任务记录）。
    case notStarted

    public var label: String {
        switch self {
        case .inProgress: "处理中"
        case .waiting: "待处理"
        case .failed: "有失败"
        case .completed: "已完成"
        case .notStarted: "未开始"
        }
    }

    /// 判定优先级：运行 > 失败 > 待执行 > 产物完整度。正在运行的资产即使
    /// 带着历史失败也归"处理中"，与列表徽章的表现一致；车道全部空闲且
    /// 产物不完整时不误报完成，归"待处理"等 reconcile 补齐。
    public static func of(_ summary: AssetProcessingSummary?) -> AssetProcessingBucket {
        guard let summary else { return .notStarted }
        if summary.segmentationStatus == .running
            || summary.evidenceRunning || summary.describeRunning {
            return .inProgress
        }
        if summary.failedCount > 0 { return .failed }
        if summary.segmentationStatus == .pending
            || summary.evidencePending > 0 || summary.describePending > 0 {
            return .waiting
        }
        guard summary.totalSegments > 0 else { return .notStarted }
        if summary.evidenceSucceeded >= summary.totalSegments,
           summary.describeSucceeded >= summary.totalSegments {
            return .completed
        }
        return .waiting
    }
}

/// 单个处理阶段（内容分片/建库/描述）的媒体级计数。done/active/failed 都以
/// 媒体为单位——片段级（job 条数）进度是车道内部视角，不属于面板。
public struct LibraryPipelineStageCounts: Equatable, Sendable {
    /// 产物覆盖该资产全部片段（或分片已定稿）的媒体数。
    public var done = 0
    /// 正在该阶段执行的媒体数。
    public var active = 0
    /// 该阶段存在失败/取消任务的媒体数。
    public var failed = 0

    public init(done: Int = 0, active: Int = 0, failed: Int = 0) {
        self.done = done
        self.active = active
        self.failed = failed
    }
}

/// 面板三阶段进度的唯一口径：分母恒为媒体总数，与 `AssetProcessingBucket`
/// 同一判定源，保证"漏斗各层"与桶统计、列表徽章永远讲同一个故事。
/// 与 job 条数口径（`IndexingProgress`，车道内部进度）刻意分离。
public struct LibraryPipelineProgress: Equatable, Sendable {
    public var totalAssets = 0
    public var segmentation = LibraryPipelineStageCounts()
    public var indexing = LibraryPipelineStageCounts()
    public var description = LibraryPipelineStageCounts()

    public init() {}

    public static func compute(
        assets: [MediaAssetRecord],
        summaries: [String: AssetProcessingSummary]
    ) -> LibraryPipelineProgress {
        var progress = LibraryPipelineProgress()
        progress.totalAssets = assets.count
        for asset in assets {
            guard let summary = summaries[asset.id] else { continue }
            // 分片已定稿 = 有片段且分片任务不在排队/运行/失败。V1 遗留
            // 资产（有片段、无 segment_asset 任务）与桶逻辑一致算已分片。
            let segmentationSettled: Bool
            switch summary.segmentationStatus {
            case .pending, .running, .failed, .cancelled:
                segmentationSettled = false
            case .succeeded, nil:
                segmentationSettled = summary.totalSegments > 0
            }
            switch summary.segmentationStatus {
            case .running:
                progress.segmentation.active += 1
            case .failed, .cancelled:
                progress.segmentation.failed += 1
            case .pending, .succeeded, nil:
                break
            }
            if segmentationSettled {
                progress.segmentation.done += 1
                // 建库/描述完成必须踩在已定稿的分片上，否则 V1 遗留片段的
                // 历史成功任务会被误报成"已建库"。
                if summary.evidenceSucceeded >= summary.totalSegments {
                    progress.indexing.done += 1
                }
                if summary.describeSucceeded >= summary.totalSegments {
                    progress.description.done += 1
                }
            }
            if summary.evidenceRunning { progress.indexing.active += 1 }
            if summary.evidenceFailed > 0 { progress.indexing.failed += 1 }
            if summary.describeRunning { progress.description.active += 1 }
            if summary.describeFailed > 0 { progress.description.failed += 1 }
        }
        return progress
    }
}

/// 视频时长分桶。桶边界为左闭右开；最后一段无上界。图片没有时间轴，
/// 不参与任何桶——时长筛选激活时图片一律不匹配，"短于 30 秒"不会混入
/// 图片。名义时长（图片的 1 秒名义段）只存在于库内部，对桶不可见。
public enum DurationBucket: String, CaseIterable, Sendable {
    case under30s
    case from30sTo5m
    case from5mTo20m
    case over20m

    static let boundariesMS: [DurationBucket: Range<Int64>] = [
        .under30s: 0..<30_000,
        .from30sTo5m: 30_000..<300_000,
        .from5mTo20m: 300_000..<1_200_000,
        .over20m: 1_200_000..<Int64.max,
    ]

    public var label: String {
        switch self {
        case .under30s: "短于 30 秒"
        case .from30sTo5m: "30 秒 – 5 分钟"
        case .from5mTo20m: "5 – 20 分钟"
        case .over20m: "长于 20 分钟"
        }
    }

    public func contains(durationMS: Int64) -> Bool {
        Self.boundariesMS[self]?.contains(durationMS) ?? false
    }

    public static func of(durationMS: Int64) -> DurationBucket {
        for bucket in Self.allCases where bucket.contains(durationMS: durationMS) {
            return bucket
        }
        return .over20m
    }
}

/// 媒体列表筛选。维度之间 AND，每个维度单选、nil 表示不限。纯内存谓词，
/// 作用在媒体库快照的全量资产上：进度维度消费的 `processingSummaries`
/// 与行内徽章、侧栏统计同源，列表与徽章不可能不一致。它是任务态不是
/// 配置态，不持久化——重启后不应带着昨天的筛选静默缩小列表。
public struct LibraryFilter: Equatable, Sendable {
    public var mediaKind: MediaKind?
    public var progress: AssetProcessingBucket?
    /// 视频时长桶；激活时图片不匹配。
    public var duration: DurationBucket?
    /// 相对路径包含（大小写不敏感）。匹配完整相对路径而不是文件名：
    /// 相机命名（IMG_0001）分布在子目录时文件名不可区分。空白表示不限。
    public var pathQuery: String

    public init(
        mediaKind: MediaKind? = nil,
        progress: AssetProcessingBucket? = nil,
        duration: DurationBucket? = nil,
        pathQuery: String = ""
    ) {
        self.mediaKind = mediaKind
        self.progress = progress
        self.duration = duration
        self.pathQuery = pathQuery
    }

    public var isActive: Bool {
        mediaKind != nil || progress != nil || duration != nil
            || !pathQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func matches(
        asset: MediaAssetRecord,
        summary: AssetProcessingSummary?
    ) -> Bool {
        if let mediaKind, asset.mediaKind != mediaKind { return false }
        if let progress, AssetProcessingBucket.of(summary) != progress { return false }
        if let duration {
            guard asset.hasTimeline, duration.contains(durationMS: asset.durationMS) else {
                return false
            }
        }
        let query = pathQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, !asset.relativePath.localizedStandardContains(query) {
            return false
        }
        return true
    }
}

/// 各筛选维度的候选计数。全局口径：不受当前筛选影响，菜单里的数字回答
/// "这一类一共有多少"，筛选后的真实结果数由列表标题表达。
public struct LibraryFilterCounts: Equatable, Sendable {
    public var totalCount = 0
    public var videoCount = 0
    public var imageCount = 0
    public var progress: [AssetProcessingBucket: Int] = [:]
    public var duration: [DurationBucket: Int] = [:]

    public init() {}

    public static func compute(
        assets: [MediaAssetRecord],
        summaries: [String: AssetProcessingSummary]
    ) -> LibraryFilterCounts {
        var counts = LibraryFilterCounts()
        for asset in assets {
            counts.totalCount += 1
            if asset.hasTimeline {
                counts.videoCount += 1
                counts.duration[DurationBucket.of(durationMS: asset.durationMS), default: 0] += 1
            } else {
                counts.imageCount += 1
            }
            let bucket = AssetProcessingBucket.of(summaries[asset.id])
            counts.progress[bucket, default: 0] += 1
        }
        return counts
    }
}

/// 列表排序。"名称"不重排——保留数据库 `relative_path COLLATE NOCASE`
/// 的原序，避免内存里的本地化比较与库内排序产生两套默认视图。其余键在
/// 内存排序，方向内建在比较器里（不能升序排完再整体倒序：那会把
/// "图片恒排视频之后"在降序时翻转成"图片排最前"），相等时以传入顺序
/// tie-break（Swift 的 sort 不稳定，必须显式保序）。
public enum LibrarySortKey: String, CaseIterable, Sendable {
    case name
    case modifiedAt
    case fileSize
    case duration
    case firstSeenAt

    public var label: String {
        switch self {
        case .name: "名称"
        case .modifiedAt: "修改时间"
        case .fileSize: "大小"
        case .duration: "时长"
        case .firstSeenAt: "入库时间"
        }
    }
}

public struct LibrarySort: Equatable, Sendable {
    public var key: LibrarySortKey
    public var ascending: Bool

    public init(key: LibrarySortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    public var isDefault: Bool { self == LibrarySort() }

    public func applied(_ assets: [MediaAssetRecord]) -> [MediaAssetRecord] {
        guard !assets.isEmpty else { return assets }
        switch key {
        case .name:
            return ascending ? assets : assets.reversed()
        case .modifiedAt, .fileSize, .duration, .firstSeenAt:
            let keyed = assets.enumerated().map { (index: $0.offset, asset: $0.element) }
            let sorted = keyed.sorted { lhs, rhs in
                ordering(lhs.asset, rhs.asset) ?? (lhs.index < rhs.index)
            }
            return sorted.map(\.asset)
        }
    }

    /// 当前方向下的严格前序；相等返回 nil，交由调用方按原序 tie-break。
    private func ordering(_ lhs: MediaAssetRecord, _ rhs: MediaAssetRecord) -> Bool? {
        switch key {
        case .name:
            return nil
        case .modifiedAt:
            return ordered(lhs.modificationDate, rhs.modificationDate)
        case .fileSize:
            return ordered(lhs.fileSize, rhs.fileSize)
        case .firstSeenAt:
            return ordered(lhs.firstSeenAt, rhs.firstSeenAt)
        case .duration:
            // 图片无时间轴，恒排视频之后，与方向无关；图片之间保持原序。
            if lhs.hasTimeline != rhs.hasTimeline { return lhs.hasTimeline }
            guard lhs.hasTimeline else { return nil }
            return ordered(lhs.durationMS, rhs.durationMS)
        }
    }

    private func ordered<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
        if lhs == rhs { return nil }
        return ascending ? lhs < rhs : lhs > rhs
    }
}
