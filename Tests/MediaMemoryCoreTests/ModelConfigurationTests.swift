import Foundation
@testable import MediaMemoryCore
import XCTest

final class ModelConfigurationTests: XCTestCase {
    func testBundledConfigurationMatchesCurrentProductionChain() throws {
        let configuration = try ModelConfiguration.loadDefault()

        XCTAssertEqual(configuration.schemaVersion, 2)
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
        XCTAssertEqual(configuration.schemaVersion, 2)
        XCTAssertEqual(configuration.asr.modelID, "replacement-asr")
        XCTAssertEqual(
            configuration.asr.endpointURL?.absoluteString,
            "http://localhost:9000/v1/audio/transcriptions"
        )
        XCTAssertEqual(configuration.embedding.modelID, "replacement-embedding")
        XCTAssertEqual(configuration.embedding.transport, .localWorker)
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
}
