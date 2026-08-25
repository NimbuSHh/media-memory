import Foundation

public enum LibraryAuthorization {
    public static func createReadOnlyBookmark(for directory: URL) throws -> Data {
        try directory.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolve(bookmark: Data) throws -> SecurityScopedLibrary {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return SecurityScopedLibrary(url: url, isBookmarkStale: isStale)
    }

    /// 书签解析可能触达慢速或离线的远程卷；异步版本在后台线程执行，
    /// 不阻塞调用方（尤其是主线程）。
    public static func resolveAsync(bookmark: Data) async throws -> SecurityScopedLibrary {
        try await Task.detached(priority: .utility) {
            try resolve(bookmark: bookmark)
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

    init(url: URL, isBookmarkStale: Bool) {
        self.url = url
        self.isBookmarkStale = isBookmarkStale
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
