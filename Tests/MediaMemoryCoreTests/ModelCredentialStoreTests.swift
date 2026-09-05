import Foundation
@testable import MediaMemoryCore
import XCTest

final class ModelCredentialStoreTests: XCTestCase {
    func testRoundTripSavesRequestedRolesAndLeavesOthersEmpty() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(asr: "asr-key", description: "description-key"),
            fileURL: fileURL,
            for: [.asr, .description]
        )

        let loaded = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: Set(ModelRole.allCases)
        )
        XCTAssertEqual(loaded.asr, "asr-key")
        XCTAssertEqual(loaded.description, "description-key")
        XCTAssertEqual(loaded.aligner, "")
        XCTAssertEqual(loaded.embedding, "")

        // 请求子集时只投影对应角色。
        let projected = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: [.embedding]
        )
        XCTAssertEqual(projected, ModelCredentials(embedding: ""))
    }

    func testSaveMergesWithRolesOutsideRequest() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(asr: "old-asr", embedding: "embedding-key"),
            fileURL: fileURL,
            for: [.asr, .embedding]
        )
        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(asr: "new-asr"),
            fileURL: fileURL,
            for: [.asr]
        )

        let loaded = try ModelCredentialStore.loadModelCredentials(fileURL: fileURL, for: .all)
        XCTAssertEqual(loaded.asr, "new-asr")
        XCTAssertEqual(loaded.embedding, "embedding-key")
    }

    func testEmptyValueClearsRole() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(description: "description-key"),
            fileURL: fileURL,
            for: [.description]
        )
        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(description: "  "),
            fileURL: fileURL,
            for: [.description]
        )

        let loaded = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: [.description]
        )
        XCTAssertEqual(loaded.description, "")
    }

    func testCredentialFileIsReadableByOwnerOnly() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(asr: "asr-key"),
            fileURL: fileURL,
            for: [.asr]
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions, NSNumber(value: 0o600))
    }

    func testMissingFileTriggersOneTimeKeychainMigration() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var cleanupCount = 0

        let loaded = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: [.asr, .description],
            keychainReader: { _ in
                ModelCredentials(asr: "old-asr", description: "old-description")
            },
            keychainCleaner: {
                cleanupCount += 1
            }
        )

        XCTAssertEqual(loaded.asr, "old-asr")
        XCTAssertEqual(loaded.description, "old-description")
        XCTAssertEqual(cleanupCount, 1)

        // 迁移结果落盘：后续读取不再触碰 keychain。
        let reloaded = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: [.asr, .description],
            keychainReader: { _ in
                XCTFail("file exists; keychain must not be read again")
                return ModelCredentials()
            },
            keychainCleaner: {
                XCTFail("file exists; keychain must not be cleaned again")
            }
        )
        XCTAssertEqual(reloaded.asr, "old-asr")
        XCTAssertEqual(reloaded.description, "old-description")
    }

    func testExistingFilePreventsKeychainAccess() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try ModelCredentialStore.saveModelCredentials(
            ModelCredentials(embedding: "file-embedding"),
            fileURL: fileURL,
            for: [.embedding]
        )

        let loaded = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: [.embedding],
            keychainReader: { _ in
                XCTFail("existing credential file must short-circuit keychain")
                return ModelCredentials()
            },
            keychainCleaner: {
                XCTFail("existing credential file must short-circuit keychain cleanup")
            }
        )

        XCTAssertEqual(loaded.embedding, "file-embedding")
    }

    func testDeniedKeychainMigrationLeavesFileAbsentForRetry() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(
            try ModelCredentialStore.loadModelCredentials(
                fileURL: fileURL,
                for: [.asr],
                keychainReader: { _ in
                    throw CredentialStoreError.keychainReadFailed(errSecAuthFailed)
                },
                keychainCleaner: {
                    XCTFail("failed migration must not clean keychain")
                }
            )
        ) { error in
            guard case CredentialStoreError.keychainReadFailed(errSecAuthFailed) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testKeychainCleanupFailureDoesNotBreakMigration() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let loaded = try ModelCredentialStore.loadModelCredentials(
            fileURL: fileURL,
            for: [.asr],
            keychainReader: { _ in ModelCredentials(asr: "old-asr") },
            keychainCleaner: {
                throw CredentialStoreError.keychainReadFailed(errSecAuthFailed)
            }
        )

        XCTAssertEqual(loaded.asr, "old-asr")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptCredentialFileThrowsInsteadOfSilentReset() throws {
        let fileURL = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertThrowsError(
            try ModelCredentialStore.loadModelCredentials(
                fileURL: fileURL,
                for: [.asr],
                keychainReader: { _ in
                    XCTFail("corrupt file must not fall back to keychain migration")
                    return ModelCredentials()
                }
            )
        ) { error in
            guard case CredentialStoreError.corruptCredentialFile = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "media-memory-credentials-\(UUID().uuidString).json")
    }
}

private extension Set where Element == ModelRole {
    static let all = Set(ModelRole.allCases)
}
