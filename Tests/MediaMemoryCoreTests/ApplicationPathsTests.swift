import Foundation
@testable import MediaMemoryCore
import XCTest

final class ApplicationPathsTests: XCTestCase {
    func testCleanupOnlyRemovesValidatedAppOwnedRunAndFrameDirectories() throws {
        let temporary = try PathsTemporaryDirectory()
        let work = temporary.url.appending(path: "Work", directoryHint: .isDirectory)
        let validJob = String(repeating: "a", count: 32)
        let linkedJob = String(repeating: "b", count: 32)

        let abandonedRun = work.appending(path: "Runs/\(validJob)/1", directoryHint: .isDirectory)
        let unrelatedRun = work.appending(path: "Runs/not-a-job/1", directoryHint: .isDirectory)
        let linkedRun = work.appending(path: "Runs/\(linkedJob)/1", directoryHint: .isDirectory)
        for directory in [abandonedRun, unrelatedRun, linkedRun] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let outside = temporary.url.appending(path: "outside.txt")
        try Data("safe".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: linkedRun.appending(path: "outside-link"),
            withDestinationURL: outside
        )

        try ApplicationPaths.cleanupAbandonedRuns(in: work)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appending(path: "Runs/\(validJob)").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedRun.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedRun.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "safe")

        let keptFrame = work.appending(path: "Frames/\(validJob)/1/00.jpg")
        let orphanFrame = work.appending(path: "Frames/\(validJob)/2/00.jpg")
        try FileManager.default.createDirectory(
            at: keptFrame.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: orphanFrame.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: keptFrame)
        try Data([2]).write(to: orphanFrame)

        try ApplicationPaths.cleanupUnreferencedFrames(
            in: work,
            referencedRelativePaths: ["Frames/\(validJob)/1/00.jpg"]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFrame.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFrame.path))

        let prefetch = work.appending(path: "Prefetch/\(validJob)", directoryHint: .isDirectory)
        let unrelatedPrefetch = work.appending(
            path: "Prefetch/not-a-job",
            directoryHint: .isDirectory
        )
        let linkedPrefetch = work.appending(
            path: "Prefetch/\(linkedJob)",
            directoryHint: .isDirectory
        )
        for directory in [prefetch, unrelatedPrefetch, linkedPrefetch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(
            at: linkedPrefetch.appending(path: "outside-link"),
            withDestinationURL: outside
        )

        try ApplicationPaths.cleanupAbandonedPrefetch(in: work)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prefetch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPrefetch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedPrefetch.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "safe")
    }

    func testApplicationInstanceLockIsExclusiveAndReleases() throws {
        let temporary = try PathsTemporaryDirectory()
        let lockURL = temporary.url.appending(path: "instance.lock")
        var first: ApplicationInstanceLock? = try ApplicationInstanceLock(url: lockURL)
        XCTAssertNotNil(first)

        XCTAssertThrowsError(try ApplicationInstanceLock(url: lockURL)) { error in
            guard case ApplicationInstanceLockError.alreadyRunning = error else {
                return XCTFail("预期单实例冲突，实际：\(error)")
            }
        }

        first = nil
        XCTAssertNoThrow(try ApplicationInstanceLock(url: lockURL))
    }
}

private final class PathsTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
