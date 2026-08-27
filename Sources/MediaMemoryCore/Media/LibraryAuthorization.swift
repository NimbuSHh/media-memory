import Foundation

public enum LibraryAuthorization {
    public static func createReadOnlyBookmark(for directory: URL) throws -> Data {
        try directory.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolve(
        bookmark: Data,
        allowMissingItemWhenParentIsReadable: Bool = false
    ) throws -> SecurityScopedLibrary {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return try SecurityScopedLibrary(
            url: url,
            isBookmarkStale: isStale,
            allowMissingItemWhenParentIsReadable: allowMissingItemWhenParentIsReadable
        )
    }

    /// 书签解析可能触达慢速或离线的远程卷；异步版本在后台线程执行，
    /// 不阻塞调用方（尤其是主线程）。
    public static func resolveAsync(
        bookmark: Data,
        allowMissingItemWhenParentIsReadable: Bool = false
    ) async throws -> SecurityScopedLibrary {
        try await Task.detached(priority: .utility) {
            try resolve(
                bookmark: bookmark,
                allowMissingItemWhenParentIsReadable: allowMissingItemWhenParentIsReadable
            )
        }.value
    }

    public static func createReadOnlyBookmarkAsync(for directory: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try createReadOnlyBookmark(for: directory)
        }.value
    }
}

public final class SecurityScopedLibrary: @unchecked Sendable {
    public let url: URL
    public let isBookmarkStale: Bool

    private let didStartAccessing: Bool

    init(
        url: URL,
        isBookmarkStale: Bool,
        allowMissingItemWhenParentIsReadable: Bool = false,
        startAccessing: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        isReadable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }
    ) throws {
        self.url = url
        self.isBookmarkStale = isBookmarkStale
        didStartAccessing = startAccessing(url)
        let readableMissingItemParent = allowMissingItemWhenParentIsReadable
            && !FileManager.default.fileExists(atPath: url.path)
            && isReadable(url.deletingLastPathComponent())
        guard didStartAccessing || isReadable(url) || readableMissingItemParent else {
            throw LibraryAuthorizationError.scopeUnavailable(url.path)
        }
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public enum LibraryAuthorizationError: Error, LocalizedError, Sendable {
    case scopeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .scopeUnavailable(path):
            "无法取得媒体位置的读取权限：\(path)"
        }
    }
}
