import Foundation

/// 媒体库根的类型：整目录授权，或单个视频文件授权。
public enum LibraryRootKind: String, Codable, Sendable {
    case directory
    case file
}

public struct LibraryRootRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let kind: LibraryRootKind
    public let bookmark: Data
    public let isEnabled: Bool
    public let createdAt: Date
    public let lastScanAt: Date?
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

    public var filename: String {
        URL(fileURLWithPath: standardizedPath).lastPathComponent
    }
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
