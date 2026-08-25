import Foundation
@testable import MediaMemoryCore
import XCTest

enum TestMediaFixture {
    static func directoryURL() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repository.appending(path: "test media", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("测试视频目录不存在")
        }
        return directory
    }

    static func videoURL() throws -> URL {
        let directory = try directoryURL()
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard MediaScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let video = candidates.first else {
            throw XCTSkip("测试视频不存在")
        }
        return video
    }
}
