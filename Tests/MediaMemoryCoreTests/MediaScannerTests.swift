import Foundation
@testable import MediaMemoryCore
import XCTest

final class MediaScannerTests: XCTestCase {
    func testSecurityScopedLibraryRejectsUnavailableScopeButAllowsReadableUnsandboxedURL() throws {
        let readable = FileManager.default.temporaryDirectory
        XCTAssertNoThrow(
            try SecurityScopedLibrary(
                url: readable,
                isBookmarkStale: false,
                startAccessing: { _ in false },
                isReadable: { _ in true }
            )
        )
        XCTAssertThrowsError(
            try SecurityScopedLibrary(
                url: readable.appending(path: "unavailable"),
                isBookmarkStale: false,
                startAccessing: { _ in false },
                isReadable: { _ in false }
            )
        ) { error in
            guard case LibraryAuthorizationError.scopeUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMissingSingleFileScopeAllowsScannerToConfirmDeletionFromReadableParent() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-missing-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let missingVideo = temporaryURL.appending(path: "deleted.mp4")

        let access = try SecurityScopedLibrary(
            url: missingVideo,
            isBookmarkStale: false,
            allowMissingItemWhenParentIsReadable: true,
            startAccessing: { _ in false },
            isReadable: { $0.standardizedFileURL == temporaryURL.standardizedFileURL }
        )
        let result = try await MediaScanner().scanFile(fileURL: access.url)

        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.isAuthoritativeComplete)
    }

    func testRealVideoIsProbedWithoutChangingSource() async throws {
        let mediaDirectory = try TestMediaFixture.directoryURL()
        let video = try TestMediaFixture.videoURL()
        let before = try FileFingerprint.snapshot(for: video)

        let result = try await MediaScanner().scan(rootURL: mediaDirectory)

        let after = try FileFingerprint.snapshot(for: video)
        XCTAssertEqual(after, before)
        XCTAssertEqual(result.unstableFileCount, 0)
        XCTAssertTrue(result.isAuthoritativeComplete)
        let asset = try XCTUnwrap(
            result.assets.first { $0.standardizedPath == video.standardizedFileURL.path }
        )
        XCTAssertEqual(asset.status, .ready)
        XCTAssertGreaterThan(asset.durationMS, 0)
        XCTAssertGreaterThan(asset.videoTrackCount, 0)
    }

    func testReadOnlySecurityScopedBookmarkResolvesDirectory() throws {
        let mediaDirectory = try TestMediaFixture.directoryURL()
        let bookmark = try LibraryAuthorization.createReadOnlyBookmark(for: mediaDirectory)
        let access = try LibraryAuthorization.resolve(bookmark: bookmark)

        XCTAssertEqual(access.url.standardizedFileURL.path, mediaDirectory.standardizedFileURL.path)
        XCTAssertFalse(access.isBookmarkStale)
    }

    func testSingleFileRootScansOnlyThatFile() async throws {
        let video = try TestMediaFixture.videoURL()
        let before = try FileFingerprint.snapshot(for: video)

        let result = try await MediaScanner().scanFile(fileURL: video)

        let after = try FileFingerprint.snapshot(for: video)
        XCTAssertEqual(after, before)
        XCTAssertEqual(result.assets.count, 1)
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.relativePath, video.lastPathComponent)
        XCTAssertEqual(asset.status, .ready)
        XCTAssertGreaterThan(asset.durationMS, 0)
    }

    func testProbeFailureProducesUncertainResultInsteadOfFailedAsset() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-probe-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let invalidVideo = temporaryURL.appending(path: "broken.mp4")
        try Data("not a video".utf8).write(to: invalidVideo)

        let result = try await MediaScanner().scanFile(fileURL: invalidVideo)

        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(result.isAuthoritativeComplete)
    }

    func testMissingSingleFileIsAuthoritativeWhenParentIsReadable() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-missing-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let missingVideo = temporaryURL.appending(path: "deleted.mp4")

        let result = try await MediaScanner().scanFile(fileURL: missingVideo)

        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.isAuthoritativeComplete)
    }

    func testLibraryRootSupportsFileKind() async throws {
        let mediaDirectory = try TestMediaFixture.directoryURL()
        let video = try TestMediaFixture.videoURL()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-scanner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let database = try MediaDatabase(url: temporaryURL.appending(path: "test.sqlite"))

        let fileRoot = try await database.addLibraryRoot(
            path: video.path,
            bookmark: Data([1]),
            kind: .file
        )
        let directoryRoot = try await database.addLibraryRoot(
            path: mediaDirectory.path,
            bookmark: Data([2]),
            kind: .directory
        )

        let roots = try await database.libraryRoots()
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.first { $0.id == fileRoot.id }?.kind, .file)
        XCTAssertEqual(roots.first { $0.id == directoryRoot.id }?.kind, .directory)
    }
}
