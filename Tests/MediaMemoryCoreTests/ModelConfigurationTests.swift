import Foundation
@testable import MediaMemoryCore
import XCTest

final class ModelConfigurationTests: XCTestCase {
    func testBundledConfigurationMatchesCurrentProductionChain() throws {
        let configuration = try ModelConfiguration.loadDefault()

        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.omlx.baseURL.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(configuration.omlx.asrModelID, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(configuration.omlx.descriptionModelID, "mlx-community/Qwen3.8-27B-4bit")
        XCTAssertEqual(
            configuration.worker.forcedAlignerModelID,
            "mlx-community/Qwen3-ForcedAligner-0.6B-bf16"
        )
        XCTAssertEqual(
            configuration.worker.embeddingModelID,
            "mlx-community/Qwen3-VL-Embedding-2B-bf16"
        )
        XCTAssertEqual(configuration.worker.pythonLauncherPath, "~/.omlx/bin/omlx-cluster-python")
        XCTAssertEqual(configuration.worker.modelRootPath, "~/.omlx/models")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try ModelConfiguration.workerScriptURL().path))
    }

    func testConfigurationCanBeReplacedByAnotherFile() throws {
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

        let configuration = try ModelConfiguration.load(from: url)

        XCTAssertEqual(configuration.omlx.asrModelID, "replacement-asr")
        XCTAssertEqual(configuration.worker.embeddingModelID, "replacement-embedding")
    }
}
