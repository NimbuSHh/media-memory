import CryptoKit
import Foundation

public enum LocalSourceCacheError: Error, LocalizedError, Sendable {
    case insufficientSpace(required: Int64, available: Int64)
    case sourceTooLarge(size: Int64, limit: Int64)
    case sourceChanged
    case invalidCachedCopy
    case cacheInUse

    public var errorDescription: String? {
        switch self {
        case let .insufficientSpace(required, available):
            "本地空间不足，缓存视频至少需要 \(Self.bytes(required))，当前可用 \(Self.bytes(available))。"
        case let .sourceTooLarge(size, limit):
            "视频大小为 \(Self.bytes(size))，超过本地缓存上限 \(Self.bytes(limit))。"
        case .sourceChanged:
            "源视频在缓存期间发生变化。"
        case .invalidCachedCopy:
            "本地视频缓存校验失败。"
        case .cacheInUse:
            "当前视频仍在处理中，暂时不能切换本地缓存。"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Keeps exactly one verified source-video snapshot on local storage.
///
/// The cache is shared by segmentation, evidence extraction, and description.
/// A different asset cannot replace the current entry while it still has active
/// jobs; AppModel releases the entry only after all jobs for that asset finish.
public actor LocalSourceCache {
    public typealias AvailableCapacity = @Sendable (URL) throws -> Int64
    public typealias AuthorizeSource = @Sendable (MediaAssetRecord) async throws -> Void

    public static let defaultMinimumFreeBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    public static let defaultMaximumSourceBytes: Int64 = 100 * 1_024 * 1_024 * 1_024

    private struct Entry {
        let assetID: String
        let fingerprint: String
        let url: URL
        let fileSize: Int64
        let contentFingerprint: String
    }

    private struct FullCopyDigest: Equatable, Sendable {
        let byteCount: Int64
        let sha256: String
    }

    private let root: URL
    private let minimumFreeBytes: Int64
    private let maximumSourceBytes: Int64
    private let availableCapacity: AvailableCapacity
    private let authorizeSource: AuthorizeSource
    private let operationGate = AsyncOperationGate()
    private var entry: Entry?
    private var activeLeaseCount = 0
    private var leaseWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        workRoot: URL,
        minimumFreeBytes: Int64 = LocalSourceCache.defaultMinimumFreeBytes,
        maximumSourceBytes: Int64 = LocalSourceCache.defaultMaximumSourceBytes,
        availableCapacity: AvailableCapacity? = nil,
        authorizeSource: @escaping AuthorizeSource = { _ in }
    ) {
        root = workRoot.standardizedFileURL
            .appending(path: "SourceCache", directoryHint: .isDirectory)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.maximumSourceBytes = max(1, maximumSourceBytes)
        self.availableCapacity = availableCapacity ?? LocalSourceCache.volumeAvailableCapacity
        self.authorizeSource = authorizeSource
    }

    public func localURL(for asset: MediaAssetRecord) async throws -> URL {
        if activeLeaseCount > 0, let entry {
            guard entry.assetID == asset.id,
                  entry.fingerprint == asset.fingerprint else {
                throw LocalSourceCacheError.cacheInUse
            }
            try validate(entry)
            return entry.url
        }
        try await operationGate.acquire()
        do {
            let url = try await materializeLocalURL(for: asset)
            await operationGate.release()
            return url
        } catch {
            await operationGate.release()
            throw error
        }
    }

    /// Keeps the cached file alive until the supplied operation has actually
    /// returned. This remains true when an outer timeout stops waiting for a
    /// non-cooperative AVFoundation task.
    public func withLocalURL<Value: Sendable>(
        for asset: MediaAssetRecord,
        operation: @escaping @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        // A timed-out AVFoundation task may keep an outer lease while a nested
        // operation asks for the same source. Reuse it directly instead of
        // waiting behind a remover that is itself waiting for that lease.
        if activeLeaseCount > 0, let entry {
            guard entry.assetID == asset.id,
                  entry.fingerprint == asset.fingerprint else {
                throw LocalSourceCacheError.cacheInUse
            }
            try validate(entry)
            activeLeaseCount += 1
            return try await runLeased(url: entry.url, operation: operation)
        }

        try await operationGate.acquire()
        let url: URL
        do {
            url = try await materializeLocalURL(for: asset)
            activeLeaseCount += 1
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }

        return try await runLeased(url: url, operation: operation)
    }

    private func runLeased<Value: Sendable>(
        url: URL,
        operation: @escaping @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await operation(url)
            releaseLease()
            return value
        } catch {
            releaseLease()
            throw error
        }
    }

    private func materializeLocalURL(for asset: MediaAssetRecord) async throws -> URL {
        if let entry,
           entry.assetID == asset.id,
           entry.fingerprint == asset.fingerprint {
            do {
                try validate(entry)
                return entry.url
            } catch {
                guard activeLeaseCount == 0 else {
                    throw LocalSourceCacheError.cacheInUse
                }
                try removeAllFiles()
                self.entry = nil
            }
        }

        try Task.checkCancellation()
        guard activeLeaseCount == 0 else {
            throw LocalSourceCacheError.cacheInUse
        }
        try removeAllFiles()
        entry = nil
        // 源访问段（授权、源读取与复制）统一归一化：除取消与本地缓存自身的
        // 已知错误外，任何失败都按“整个源暂时不可访问”上报，由应用层决定
        // 停车；单视频自身问题（内容变化、缓存校验、本地容量）不在此列。
        do {
            let url = try await copySourceThroughCache(asset)
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalSourceCacheError {
            throw error
        } catch let error as SourceUnavailableError {
            throw error
        } catch {
            throw SourceUnavailableError(rootID: asset.rootID, underlying: error)
        }
    }

    /// 从源复制并校验；失败由调用方在源缓存边界归一化为源不可用。
    private func copySourceThroughCache(_ asset: MediaAssetRecord) async throws -> URL {
        // Resolving a security-scoped bookmark may wake an offline NAS. Do it
        // only when a processing lane actually needs to materialize this source.
        try await authorizeSource(asset)
        try Task.checkCancellation()
        let sourceURL = URL(fileURLWithPath: asset.standardizedPath).standardizedFileURL
        let before = try FileFingerprint.snapshot(for: sourceURL)
        let beforeFingerprint = try FileFingerprint.lightFingerprint(for: sourceURL, snapshot: before)
        let sourceContentFingerprint = try FileFingerprint.sampledContentFingerprint(
            for: sourceURL,
            snapshot: before
        )
        guard beforeFingerprint == asset.fingerprint else {
            throw LocalSourceCacheError.sourceChanged
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let available = try availableCapacity(root)
        let (sum, overflow) = before.fileSize.addingReportingOverflow(minimumFreeBytes)
        let required = overflow ? Int64.max : sum
        guard available >= required else {
            throw LocalSourceCacheError.insufficientSpace(required: required, available: available)
        }
        let proportionalLimit = max(1, available / 4)
        let effectiveLimit = min(maximumSourceBytes, proportionalLimit)
        guard before.fileSize <= effectiveLimit else {
            throw LocalSourceCacheError.sourceTooLarge(
                size: before.fileSize,
                limit: effectiveLimit
            )
        }

        let key = SHA256.hash(data: Data(asset.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let partialDirectory = root.appending(
            path: ".partial-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let finalDirectory = root.appending(path: key, directoryHint: .isDirectory)
        let extensionValue = sourceURL.pathExtension
        let filename = extensionValue.isEmpty ? "source" : "source.\(extensionValue)"
        let partialURL = partialDirectory.appending(path: filename)
        let finalURL = finalDirectory.appending(path: filename)

        try FileManager.default.createDirectory(
            at: partialDirectory,
            withIntermediateDirectories: true
        )
        do {
            let copiedDigest = try await Self.copyFile(from: sourceURL, to: partialURL)
            let after = try FileFingerprint.snapshot(for: sourceURL)
            let afterFingerprint = try FileFingerprint.lightFingerprint(for: sourceURL, snapshot: after)
            guard after == before, afterFingerprint == asset.fingerprint else {
                throw LocalSourceCacheError.sourceChanged
            }

            let cachedSnapshot = try FileFingerprint.snapshot(for: partialURL)
            let cachedContentFingerprint = try FileFingerprint.sampledContentFingerprint(
                for: partialURL,
                snapshot: cachedSnapshot
            )
            let cachedDigest = try await Self.fullDigest(of: partialURL)
            guard cachedSnapshot.fileSize == before.fileSize,
                  cachedContentFingerprint == sourceContentFingerprint,
                  cachedDigest == copiedDigest else {
                throw LocalSourceCacheError.invalidCachedCopy
            }

            try? FileManager.default.removeItem(at: finalDirectory)
            try FileManager.default.moveItem(at: partialDirectory, to: finalDirectory)
            entry = Entry(
                assetID: asset.id,
                fingerprint: asset.fingerprint,
                url: finalURL,
                fileSize: before.fileSize,
                contentFingerprint: sourceContentFingerprint
            )
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: partialDirectory)
            throw error
        }
    }

    public func cachedAssetID() -> String? {
        guard let entry, FileManager.default.fileExists(atPath: entry.url.path) else {
            self.entry = nil
            return nil
        }
        return entry.assetID
    }

    public func validateLocalURL(_ url: URL, for asset: MediaAssetRecord) throws {
        guard let entry,
              entry.assetID == asset.id,
              entry.fingerprint == asset.fingerprint,
              entry.url == url else {
            throw LocalSourceCacheError.invalidCachedCopy
        }
        try validate(entry)
    }

    public func remove(assetID: String) async throws {
        _ = try await removeIfUnused(assetID: assetID) { true }
    }

    public func removeIfUnused(
        assetID: String,
        canRemove: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        try await operationGate.acquire()
        do {
            guard entry?.assetID == assetID else {
                await operationGate.release()
                return false
            }
            guard try await canRemove() else {
                await operationGate.release()
                return false
            }
            await waitForLeases()
            guard try await canRemove() else {
                await operationGate.release()
                return false
            }
            try removeAllFiles()
            entry = nil
            await operationGate.release()
            return true
        } catch {
            await operationGate.release()
            throw error
        }
    }

    public func removeAll() async throws {
        try await operationGate.acquire()
        do {
            await waitForLeases()
            try removeAllFiles()
            entry = nil
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    public static func cleanupAbandoned(in workRoot: URL) throws {
        let root = workRoot.standardizedFileURL
            .appending(path: "SourceCache", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    private func removeAllFiles() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    private func validate(_ entry: Entry) throws {
        let snapshot = try FileFingerprint.snapshot(for: entry.url)
        let fingerprint = try FileFingerprint.sampledContentFingerprint(
            for: entry.url,
            snapshot: snapshot
        )
        guard snapshot.fileSize == entry.fileSize,
              fingerprint == entry.contentFingerprint else {
            throw LocalSourceCacheError.invalidCachedCopy
        }
    }

    private func waitForLeases() async {
        guard activeLeaseCount > 0 else { return }
        await withCheckedContinuation { continuation in
            leaseWaiters.append(continuation)
        }
    }

    private func releaseLease() {
        activeLeaseCount = max(0, activeLeaseCount - 1)
        guard activeLeaseCount == 0 else { return }
        let waiters = leaseWaiters
        leaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private nonisolated static func volumeAvailableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let value = values.volumeAvailableCapacityForImportantUsage {
            return max(0, value)
        }
        if let value = values.volumeAvailableCapacity {
            return max(0, Int64(value))
        }
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: url.path
        )
        if let value = attributes[.systemFreeSize] as? NSNumber {
            return max(0, value.int64Value)
        }
        return 0
    }

    private nonisolated static func copyFile(
        from source: URL,
        to destination: URL
    ) async throws -> FullCopyDigest {
        let task = Task.detached(priority: .utility) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            var hasher = SHA256()
            var byteCount: Int64 = 0
            defer {
                try? input.close()
                try? output.close()
            }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 4 * 1_024 * 1_024),
                      !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                byteCount += Int64(chunk.count)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            return FullCopyDigest(
                byteCount: byteCount,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func fullDigest(of url: URL) async throws -> FullCopyDigest {
        let task = Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: url)
            var hasher = SHA256()
            var byteCount: Int64 = 0
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 4 * 1_024 * 1_024),
                      !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                byteCount += Int64(chunk.count)
            }
            return FullCopyDigest(
                byteCount: byteCount,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
