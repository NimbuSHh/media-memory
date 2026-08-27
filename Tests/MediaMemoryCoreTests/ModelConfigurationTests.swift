import Foundation
import Security
@testable import MediaMemoryCore
import XCTest

final class ModelConfigurationTests: XCTestCase {
    func testBundledConfigurationMatchesCurrentProductionChain() throws {
        let configuration = try ModelConfiguration.loadDefault()

        XCTAssertEqual(configuration.schemaVersion, 3)
        XCTAssertEqual(configuration.asr.transport, .openAITranscription)
        XCTAssertEqual(
            configuration.asr.endpointURL?.absoluteString,
            "http://127.0.0.1:8000/v1/audio/transcriptions"
        )
        XCTAssertEqual(configuration.asr.modelID, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(configuration.description.modelID, "mlx-community/Qwen3.8-27B-4bit")
        XCTAssertEqual(
            configuration.aligner.modelID,
            "mlx-community/Qwen3-ForcedAligner-0.6B-bf16"
        )
        XCTAssertEqual(
            configuration.embedding.modelID,
            "mlx-community/Qwen3-VL-Embedding-2B-bf16"
        )
        XCTAssertEqual(configuration.aligner.transport, .localWorker)
        XCTAssertEqual(configuration.embedding.transport, .localWorker)
        XCTAssertTrue(configuration.credentialRoles.isEmpty)
        XCTAssertEqual(configuration.asr.authentication, .none)
        XCTAssertEqual(configuration.description.authentication, .none)
        XCTAssertEqual(configuration.localWorker?.pythonLauncherPath, "~/.omlx/bin/omlx-cluster-python")
        XCTAssertEqual(configuration.localWorker?.modelRootPath, "~/.omlx/models")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try ModelConfiguration.workerScriptURL().path))
    }

    func testSchemaOneConfigurationMigratesWithoutChangingModels() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "omlx": {
                "baseURL": "http://localhost:9000/v1",
                "asrModelID": "replacement-asr",
                "descriptionModelID": "replacement-description"
              },
              "worker": {
                "forcedAlignerModelID": "replacement-aligner",
                "embeddingModelID": "replacement-embedding",
                "pythonLauncherPath": "/tmp/python",
                "modelRootPath": "/tmp/models"
              }
            }
            """.utf8
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-models-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ModelConfigurationStore.loadForStartup(from: url)
        let configuration = loaded.configuration

        XCTAssertTrue(loaded.canAdoptLegacyModelIdentities)
        XCTAssertEqual(loaded.authenticationMigrationRoles, [.asr, .description])
        XCTAssertEqual(configuration.schemaVersion, 3)
        XCTAssertEqual(configuration.asr.modelID, "replacement-asr")
        XCTAssertEqual(
            configuration.asr.endpointURL?.absoluteString,
            "http://localhost:9000/v1/audio/transcriptions"
        )
        XCTAssertEqual(configuration.embedding.modelID, "replacement-embedding")
        XCTAssertEqual(configuration.embedding.transport, .localWorker)
        XCTAssertTrue(configuration.credentialRoles.isEmpty)
    }

    func testSavedSchemaTwoConfigurationCannotSilentlyAdoptBareLegacyIdentities() throws {
        let source = ModelConfiguration(
            asr: ModelEndpoint(
                transport: .openAITranscription,
                endpointURL: URL(string: "https://replacement.example/v1/audio/transcriptions"),
                modelID: "same-asr-name"
            ),
            aligner: ModelEndpoint(
                transport: .mediaMemoryAlignment,
                endpointURL: URL(string: "https://replacement.example/alignment"),
                modelID: "same-aligner-name"
            ),
            embedding: ModelEndpoint(
                transport: .mediaMemoryEmbedding,
                endpointURL: URL(string: "https://replacement.example/embedding"),
                modelID: "same-embedding-name"
            ),
            description: ModelEndpoint(
                transport: .openAIChatCompletion,
                endpointURL: URL(string: "https://replacement.example/v1/chat/completions"),
                modelID: "same-description-name"
            ),
            localWorker: nil
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-models-\(UUID().uuidString).json")
        try JSONEncoder().encode(source).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ModelConfigurationStore.loadForStartup(from: url)

        XCTAssertFalse(loaded.canAdoptLegacyModelIdentities)
        XCTAssertTrue(loaded.authenticationMigrationRoles.isEmpty)
        XCTAssertEqual(loaded.configuration.asr.modelID, source.asr.modelID)
        XCTAssertEqual(loaded.configuration.asr.endpointURL, source.asr.endpointURL)
    }

    func testDerivationIdentityChangesWithEndpointButNotCredentials() throws {
        let first = ModelEndpoint(
            transport: .openAITranscription,
            endpointURL: URL(string: "https://one.example/v1/audio/transcriptions"),
            modelID: "shared-name"
        )
        let second = ModelEndpoint(
            transport: .openAITranscription,
            endpointURL: URL(string: "https://two.example/v1/audio/transcriptions"),
            modelID: "shared-name"
        )

        XCTAssertNotEqual(first.derivationID, second.derivationID)
    }

    func testSchemaTwoInfersLocalNoAuthAndRemoteBearerWithoutChangingDerivation() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "asr": {
                "transport": "openai_audio_transcriptions",
                "endpointURL": "http://127.0.0.1:8000/v1/audio/transcriptions",
                "modelID": "local-asr"
              },
              "aligner": {
                "transport": "media_memory_alignment",
                "endpointURL": "https://models.example/alignment",
                "modelID": "remote-aligner"
              },
              "embedding": {
                "transport": "local_worker",
                "modelID": "local-embedding"
              },
              "description": {
                "transport": "openai_chat_completions",
                "endpointURL": "http://localhost:8000/v1/chat/completions",
                "modelID": "local-description"
              },
              "localWorker": {
                "forcedAlignerModelID": "unused",
                "embeddingModelID": "local-embedding",
                "pythonLauncherPath": "/tmp/python",
                "modelRootPath": "/tmp/models"
              }
            }
            """.utf8
        )
        let configuration = try JSONDecoder().decode(ModelConfiguration.self, from: data)

        XCTAssertEqual(configuration.schemaVersion, 3)
        XCTAssertEqual(configuration.asr.authentication, .none)
        XCTAssertEqual(configuration.description.authentication, .none)
        XCTAssertEqual(configuration.embedding.authentication, .none)
        XCTAssertEqual(configuration.aligner.authentication, .bearer)
        XCTAssertEqual(configuration.credentialRoles, [.aligner])
    }

    func testSchemaTwoStoreMarksEveryInferredHTTPAuthenticationForConfirmation() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "asr": {
                "transport": "openai_audio_transcriptions",
                "endpointURL": "http://127.0.0.1:8000/v1/audio/transcriptions",
                "modelID": "local-asr"
              },
              "aligner": {
                "transport": "media_memory_alignment",
                "endpointURL": "https://models.example/alignment",
                "modelID": "remote-aligner"
              },
              "embedding": {
                "transport": "local_worker",
                "modelID": "local-embedding"
              },
              "description": {
                "transport": "openai_chat_completions",
                "endpointURL": "http://localhost:8000/v1/chat/completions",
                "modelID": "local-description"
              },
              "localWorker": {
                "forcedAlignerModelID": "unused",
                "embeddingModelID": "local-embedding",
                "pythonLauncherPath": "/tmp/python",
                "modelRootPath": "/tmp/models"
              }
            }
            """.utf8
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-models-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ModelConfigurationStore.loadForStartup(from: url)

        XCTAssertEqual(loaded.authenticationMigrationRoles, [.asr, .aligner, .description])
        XCTAssertEqual(loaded.configuration.asr.authentication, .none)
        XCTAssertEqual(loaded.configuration.aligner.authentication, .bearer)
    }

    func testAuthenticationRoundTripAndEmptyCredentialRoleLoadAvoidsKeychain() throws {
        let endpoint = ModelEndpoint(
            transport: .openAIChatCompletion,
            endpointURL: URL(string: "https://models.example/chat/completions"),
            modelID: "description",
            authentication: .bearer
        )
        let decoded = try JSONDecoder().decode(
            ModelEndpoint.self,
            from: JSONEncoder().encode(endpoint)
        )

        XCTAssertEqual(decoded, endpoint)
        XCTAssertEqual(try KeychainStore.loadModelCredentials(for: []), ModelCredentials())
    }

    func testSchemaOnePreservesRemoteBearerAuthentication() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "omlx": {
                "baseURL": "https://models.example/v1/",
                "asrModelID": "remote-asr",
                "descriptionModelID": "remote-description"
              },
              "worker": {
                "forcedAlignerModelID": "local-aligner",
                "embeddingModelID": "local-embedding",
                "pythonLauncherPath": "/tmp/python",
                "modelRootPath": "/tmp/models"
              }
            }
            """.utf8
        )

        let configuration = try JSONDecoder().decode(ModelConfiguration.self, from: data)

        XCTAssertEqual(configuration.asr.authentication, .bearer)
        XCTAssertEqual(configuration.description.authentication, .bearer)
        XCTAssertEqual(configuration.credentialRoles, [.asr, .description])
    }

    func testExplicitCredentialMigrationReplacesOnlyRequestedRoles() throws {
        let credentials = ModelCredentials(
            asr: "new-asr",
            aligner: "new-aligner",
            embedding: "new-embedding",
            description: "new-description"
        )
        var replacements: [(ModelRole, String)] = []

        try KeychainStore.replaceCredentialsForMigration(
            credentials,
            roles: [.asr, .description]
        ) { role, value in
            replacements.append((role, value))
        }

        XCTAssertEqual(replacements.map(\.0), [.asr, .description])
        XCTAssertEqual(replacements.map(\.1), ["new-asr", "new-description"])
        XCTAssertTrue(KeychainError.status(errSecAuthFailed).isAccessDenied)
        XCTAssertFalse(KeychainError.status(errSecParam).isAccessDenied)
    }

    func testExplicitCredentialMigrationReportsPartialProgressAndCanBeRetried() throws {
        enum ExpectedFailure: Error { case denied }
        let credentials = ModelCredentials(asr: "asr", description: "description")

        XCTAssertThrowsError(
            try KeychainStore.replaceCredentialsForMigration(
                credentials,
                roles: [.asr, .description]
            ) { role, _ in
                if role == .description { throw ExpectedFailure.denied }
            }
        ) { error in
            guard case let KeychainError.migrationPartiallyCompleted(
                completedAccounts,
                failedAccount,
                _
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(completedAccounts, [ModelRole.asr.rawValue])
            XCTAssertEqual(failedAccount, ModelRole.description.rawValue)
        }
    }
}
