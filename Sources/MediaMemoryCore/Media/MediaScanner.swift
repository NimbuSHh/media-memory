import Foundation

public enum MediaScanError: Error, LocalizedError, Sendable {
    case invalidRoot(String)
    case invalidRegularFile(String)
    case unsupportedFileType(String)
    case invalidDuration(String)
    case missingVideoTrack(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRoot(path):
            "无法读取媒体目录：\(path)"
        case let .invalidRegularFile(path):
            "不是可读取的普通文件：\(path)"
        case let .unsupportedFileType(path):
            "不支持的媒体文件类型：\(path)"
        case let .invalidDuration(path):
            "媒体时长无效：\(path)"
        case let .missingVideoTrack(path):
            "媒体没有视频轨道：\(path)"
        }
    }
}

/// 轻量刷新用的候选文件：只有一次 stat 得到的元数据快照，
/// 不包含任何探测产物。是否需要探测由数据库按既有记录分类决定。
public struct MediaScanCandidate: Equatable, Sendable {
    public let relativePath: String
    public let standardizedPath: String
    public let fileIdentifier: String?
    public let fileSize: Int64
    public let modificationDate: Date

    public init(
        relativePath: String,
        standardizedPath: String,
        fileIdentifier: String?,
        fileSize: Int64,
        modificationDate: Date
    ) {
        self.relativePath = relativePath
        self.standardizedPath = standardizedPath
        self.fileIdentifier = fileIdentifier
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }
}

/// 刷新管线第一步的产物：完整枚举到的候选列表。`errors` 非空表示部分
/// 子目录不可读，此时枚举不完整，不得据此判定"未出现 = 已缺失"。
public struct MediaScanEnumeration: Sendable {
    public let candidates: [MediaScanCandidate]
    public let skippedFileCount: Int
    public let errors: [String]

    public var isComplete: Bool { errors.isEmpty }
}

public struct MediaScanner: Sendable {
    public static let supportedExtensions: Set<String> = [
        "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mts", "webm"
    ]

    public init() {}

    /// 单文件根：跳过目录枚举，只做同一套稳定性检查与探测。
    public func scanFile(fileURL: URL) async throws -> MediaScanResult {
        try Task.checkCancellation()
        let url = fileURL.standardizedFileURL
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw MediaScanError.unsupportedFileType(url.path)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
            if (try? isConfirmedAbsent(url)) == true {
                return MediaScanResult(
                    assets: [],
                    unstableFileCount: 0,
                    skippedFileCount: 0,
                    errors: [],
                    isAuthoritativeComplete: true
                )
            }
            return MediaScanResult(
                assets: [],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: ["\(url.path)：\(error.localizedDescription)"],
                isAuthoritativeComplete: false
            )
        }
        guard values.isRegularFile == true else {
            throw MediaScanError.invalidRegularFile(url.path)
        }

        let firstSnapshot = try FileFingerprint.snapshot(for: url)
        try await Task.sleep(for: .milliseconds(750))
        try Task.checkCancellation()
        let secondSnapshot = try FileFingerprint.snapshot(for: url)
        guard secondSnapshot == firstSnapshot else {
            return MediaScanResult(
                assets: [],
                unstableFileCount: 1,
                skippedFileCount: 0,
                errors: []
            )
        }
        let inspection = await inspect(url, root: url, snapshot: secondSnapshot)
        return MediaScanResult(
            assets: inspection.asset.map { [$0] } ?? [],
            unstableFileCount: 0,
            skippedFileCount: 0,
            errors: inspection.error.map { [$0] } ?? []
        )
    }

    /// A missing file is authoritative only when its parent directory can be
    /// listed successfully and the exact entry is absent. Offline/permission
    /// failures remain uncertain and preserve the previous ready asset.
    private func isConfirmedAbsent(_ fileURL: URL) throws -> Bool {
        let parent = fileURL.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return false }
        let entries = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        )
        return !entries.contains {
            $0.standardizedFileURL.path == fileURL.standardizedFileURL.path
        }
    }

    /// 刷新管线第一步：枚举目录并记录每个候选文件的元数据快照。
    /// 只读目录与 stat，不读文件内容、不探测媒体。
    public func enumerateRoot(rootURL: URL) throws -> MediaScanEnumeration {
        try Task.checkCancellation()
        let root = rootURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw MediaScanError.invalidRoot(root.path)
        }
        let firstPass = try enumerateCandidates(root: root)
        return MediaScanEnumeration(
            candidates: firstPass.candidates.map(\.info),
            skippedFileCount: firstPass.skippedCount,
            errors: firstPass.errors
        )
    }

    /// 刷新管线第二步：只对"新增或元数据已变"的候选做稳定窗复查与探测。
    /// 未变化文件不进入该列表，因此不会被逐个打开。
    public func probeFiles(
        rootURL: URL,
        candidates: [MediaScanCandidate]
    ) async throws -> MediaScanResult {
        try Task.checkCancellation()
        let root = rootURL.standardizedFileURL
        guard !candidates.isEmpty else {
            return MediaScanResult(assets: [], unstableFileCount: 0, skippedFileCount: 0, errors: [])
        }
        try await Task.sleep(for: .milliseconds(750))
        try Task.checkCancellation()

        var assets: [ScannedMediaAsset] = []
        var unstableCount = 0
        var errors: [String] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: candidate.standardizedPath)
            do {
                let enumerationSnapshot = MediaFileSnapshot(
                    fileSize: candidate.fileSize,
                    modificationDate: candidate.modificationDate,
                    fileIdentifier: candidate.fileIdentifier
                )
                let secondSnapshot = try FileFingerprint.snapshot(for: url)
                guard secondSnapshot == enumerationSnapshot else {
                    unstableCount += 1
                    continue
                }
                let inspection = await inspect(url, root: root, snapshot: secondSnapshot)
                if let asset = inspection.asset {
                    assets.append(asset)
                }
                if let error = inspection.error {
                    errors.append(error)
                }
            } catch {
                errors.append("\(url.path)：\(error.localizedDescription)")
            }
        }

        return MediaScanResult(
            assets: assets.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            unstableFileCount: unstableCount,
            skippedFileCount: 0,
            errors: errors
        )
    }

    public func scan(rootURL: URL) async throws -> MediaScanResult {
        try Task.checkCancellation()
        let root = rootURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw MediaScanError.invalidRoot(root.path)
        }

        let firstPass = try enumerateCandidates(root: root)
        try await Task.sleep(for: .milliseconds(750))

        var assets: [ScannedMediaAsset] = []
        var unstableCount = 0
        var errors = firstPass.errors

        for candidate in firstPass.candidates {
            try Task.checkCancellation()
            do {
                let secondSnapshot = try FileFingerprint.snapshot(for: candidate.url)
                guard secondSnapshot == candidate.snapshot else {
                    unstableCount += 1
                    continue
                }
                let inspection = await inspect(
                    candidate.url,
                    root: root,
                    snapshot: secondSnapshot
                )
                if let asset = inspection.asset {
                    assets.append(asset)
                }
                if let error = inspection.error {
                    errors.append(error)
                }
            } catch {
                errors.append("\(candidate.url.path)：\(error.localizedDescription)")
            }
        }

        return MediaScanResult(
            assets: assets.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            unstableFileCount: unstableCount,
            skippedFileCount: firstPass.skippedCount,
            errors: errors
        )
    }

    private struct Candidate {
        let url: URL
        let info: MediaScanCandidate

        var snapshot: MediaFileSnapshot {
            MediaFileSnapshot(
                fileSize: info.fileSize,
                modificationDate: info.modificationDate,
                fileIdentifier: info.fileIdentifier
            )
        }
    }

    private func enumerateCandidates(
        root: URL
    ) throws -> (candidates: [Candidate], skippedCount: Int, errors: [String]) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        var enumerationErrors: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationErrors.append("\(url.path)：\(error.localizedDescription)")
                return true
            }
        ) else {
            return ([], 0, [MediaScanError.invalidRoot(root.path).localizedDescription])
        }

        var candidates: [Candidate] = []
        var skippedCount = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    skippedCount += 1
                    continue
                }
                if values.isDirectory == true {
                    continue
                }
                guard values.isRegularFile == true,
                      Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                      isInside(url: url, root: root) else {
                    skippedCount += 1
                    continue
                }
                let snapshot = try FileFingerprint.snapshot(for: url)
                candidates.append(
                    Candidate(
                        url: url.standardizedFileURL,
                        info: MediaScanCandidate(
                            relativePath: makeRelativePath(url: url, root: root),
                            standardizedPath: url.standardizedFileURL.path,
                            fileIdentifier: snapshot.fileIdentifier,
                            fileSize: snapshot.fileSize,
                            modificationDate: snapshot.modificationDate
                        )
                    )
                )
            } catch {
                enumerationErrors.append("\(url.path)：\(error.localizedDescription)")
            }
        }
        return (candidates, skippedCount, enumerationErrors)
    }

    private struct InspectionOutcome {
        let asset: ScannedMediaAsset?
        let error: String?
    }

    private func inspect(
        _ url: URL,
        root: URL,
        snapshot: MediaFileSnapshot
    ) async -> InspectionOutcome {
        let relativePath = makeRelativePath(url: url, root: root)
        let fingerprint: String
        do {
            fingerprint = try FileFingerprint.lightFingerprint(for: url, snapshot: snapshot)
        } catch {
            return InspectionOutcome(
                asset: nil,
                error: "\(url.path)：读取指纹失败：\(error.localizedDescription)"
            )
        }

        do {
            let probe = try await MediaProbe.inspect(url: url)
            return InspectionOutcome(
                asset: ScannedMediaAsset(
                    relativePath: relativePath,
                    standardizedPath: url.standardizedFileURL.path,
                    fileIdentifier: snapshot.fileIdentifier,
                    fileSize: snapshot.fileSize,
                    modificationDate: snapshot.modificationDate,
                    durationMS: probe.durationMS,
                    videoTrackCount: probe.videoTrackCount,
                    audioTrackCount: probe.audioTrackCount,
                    isPlayable: probe.isPlayable,
                    fingerprint: fingerprint,
                    status: probe.isPlayable ? .ready : .failed,
                    errorMessage: probe.isPlayable ? nil : "AVFoundation 判定该媒体不可播放"
                ),
                error: nil
            )
        } catch {
            return InspectionOutcome(
                asset: nil,
                error: "\(url.path)：\(error.localizedDescription)"
            )
        }
    }

    private func isInside(url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func makeRelativePath(url: URL, root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(prefix.count))
    }
}
