import Foundation

/// 媒体库根的类型：整目录授权，或单个媒体文件授权。
public enum LibraryRootKind: String, Codable, Sendable {
    case directory
    case file
}

/// 媒体类型。只在四个物理入口产生分支：探测、分段、建库抽帧、描述
/// prompt；其余管线（job、证据、向量、检索、激活门控）对类型无感知。
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video
    case image

    /// 动图（GIF 等）本次不支持；该集合只收静态图。
    public static let imageExtensions: Set<String> = [
        "avif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    public static let videoExtensions: Set<String> = [
        "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mts", "webm"
    ]

    public static var supportedExtensions: Set<String> {
        videoExtensions.union(imageExtensions)
    }

    public init?(forExtension raw: String) {
        let ext = raw.lowercased()
        if Self.videoExtensions.contains(ext) {
            self = .video
        } else if Self.imageExtensions.contains(ext) {
            self = .image
        } else {
            return nil
        }
    }

    /// 图片没有时间轴，但片段覆盖校验（`end_ms > start_ms` 与"恰好盖满
    /// 权威时长"）、OCR 观察窗与检索证据区间都建立在时间轴之上。探测时
    /// 为图片赋予名义时长，语义分段由此产出覆盖全部内容的单一名义段。
    /// 名义值对用户不可见：所有展示点按 `hasTimeline` 隐藏时间。
    public var nominalDurationMS: Int64? {
        self == .image ? 1_000 : nil
    }
}

public struct LibraryRootRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let kind: LibraryRootKind
    public let bookmark: Data
    public let isEnabled: Bool
    public let createdAt: Date
    public let lastScanAt: Date?
    /// 处理队列位置：值越小越先处理。只被"新库追加队尾"和"移到队首"
    /// 两个动作改变；库完成处理后 rank 保留，重新产生任务时回到原位置。
    public let processingRank: Int

    public init(
        id: String,
        path: String,
        kind: LibraryRootKind,
        bookmark: Data,
        isEnabled: Bool,
        createdAt: Date,
        lastScanAt: Date?,
        processingRank: Int = 0
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.bookmark = bookmark
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastScanAt = lastScanAt
        self.processingRank = processingRank
    }
}

extension LibraryRootRecord {
    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

public enum MediaAssetStatus: String, Codable, Sendable {
    case ready
    case failed
    case missing
}

public struct MediaAssetRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let rootID: String
    public let relativePath: String
    public let standardizedPath: String
    public let fileSize: Int64
    public let modificationDate: Date
    public let durationMS: Int64
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let isPlayable: Bool
    public let fingerprint: String
    public let status: MediaAssetStatus
    public let errorMessage: String?
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let mediaKind: MediaKind
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: String,
        rootID: String,
        relativePath: String,
        standardizedPath: String,
        fileSize: Int64,
        modificationDate: Date,
        durationMS: Int64,
        videoTrackCount: Int,
        audioTrackCount: Int,
        isPlayable: Bool,
        fingerprint: String,
        status: MediaAssetStatus,
        errorMessage: String?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        mediaKind: MediaKind = .video,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) {
        self.id = id
        self.rootID = rootID
        self.relativePath = relativePath
        self.standardizedPath = standardizedPath
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.durationMS = durationMS
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.isPlayable = isPlayable
        self.fingerprint = fingerprint
        self.status = status
        self.errorMessage = errorMessage
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.mediaKind = mediaKind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var filename: String {
        URL(fileURLWithPath: standardizedPath).lastPathComponent
    }

    /// 媒体是否有真实时间轴。图片的名义段时长对用户不可见：
    /// 所有展示点用该属性决定是否渲染时间信息。
    public var hasTimeline: Bool { mediaKind == .video }
}

public struct SegmentRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let assetID: String
    public let ordinal: Int
    public let startMS: Int64
    public let endMS: Int64
    public let segmentationVersion: Int
}

public struct ScannedMediaAsset: Equatable, Sendable {
    public let relativePath: String
    public let standardizedPath: String
    public let fileIdentifier: String?
    public let fileSize: Int64
    public let modificationDate: Date
    public let durationMS: Int64
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let isPlayable: Bool
    public let fingerprint: String
    public let status: MediaAssetStatus
    public let errorMessage: String?
    public let mediaKind: MediaKind
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        relativePath: String,
        standardizedPath: String,
        fileIdentifier: String?,
        fileSize: Int64,
        modificationDate: Date,
        durationMS: Int64,
        videoTrackCount: Int,
        audioTrackCount: Int,
        isPlayable: Bool,
        fingerprint: String,
        status: MediaAssetStatus,
        errorMessage: String?,
        mediaKind: MediaKind = .video,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) {
        self.relativePath = relativePath
        self.standardizedPath = standardizedPath
        self.fileIdentifier = fileIdentifier
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.durationMS = durationMS
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.isPlayable = isPlayable
        self.fingerprint = fingerprint
        self.status = status
        self.errorMessage = errorMessage
        self.mediaKind = mediaKind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 轻量刷新计划：`unchangedRelativePaths` 是元数据与库内记录一致的文件，
/// 只刷新可见性；`toProbe` 是新增或已变化的文件，需要完整探测。
public struct ScanRefreshPlan: Sendable {
    public let unchangedRelativePaths: [String]
    public let toProbe: [MediaScanCandidate]

    public init(unchangedRelativePaths: [String], toProbe: [MediaScanCandidate]) {
        self.unchangedRelativePaths = unchangedRelativePaths
        self.toProbe = toProbe
    }
}

public struct MediaScanResult: Equatable, Sendable {
    public let assets: [ScannedMediaAsset]
    public let unstableFileCount: Int
    public let skippedFileCount: Int
    public let errors: [String]
    /// 只有完整、稳定且无读取错误的扫描，才足以证明“未出现的旧资产已缺失”。
    /// 不确定扫描仍可提交成功观察到的资产，但不得据此使其他资产失效。
    public let isAuthoritativeComplete: Bool

    public init(
        assets: [ScannedMediaAsset],
        unstableFileCount: Int,
        skippedFileCount: Int,
        errors: [String],
        isAuthoritativeComplete: Bool? = nil
    ) {
        self.assets = assets
        self.unstableFileCount = unstableFileCount
        self.skippedFileCount = skippedFileCount
        self.errors = errors
        self.isAuthoritativeComplete = isAuthoritativeComplete
            ?? (unstableFileCount == 0 && errors.isEmpty)
    }
}
