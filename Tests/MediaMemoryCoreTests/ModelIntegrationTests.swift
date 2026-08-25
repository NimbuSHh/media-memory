import Foundation
@testable import MediaMemoryCore
import XCTest

final class ModelIntegrationTests: XCTestCase {
    func testRealASRAlignmentOCRAndEmbedding() async throws {
        guard ProcessInfo.processInfo.environment["MEDIA_MEMORY_RUN_MODEL_TESTS"] == "1" else {
            throw XCTSkip("设置 MEDIA_MEMORY_RUN_MODEL_TESTS=1 后运行真实模型测试")
        }
        let configuration = try ModelConfiguration.loadDefault()
        let apiKey = try mediaMemorySubkey()
        let video = try testVideoURL()
        let workRoot = try ApplicationPaths.workDirectoryURL()
        let runDirectory = workRoot
            .appending(path: "Integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let audio = runDirectory.appending(path: "sample.wav")
        _ = try await AudioSegmentExtractor.extractWAV(
            assetURL: video,
            startMS: 0,
            endMS: 6_000,
            destinationURL: audio
        )
        let client = OMLXClient(baseURL: configuration.omlx.baseURL, apiKey: apiKey)
        let transcription = try await client.transcribe(
            audioURL: audio,
            modelID: configuration.omlx.asrModelID
        )
        XCTAssertFalse(transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let worker = try MLXWorker(configuration: configuration.worker, workRoot: workRoot)
        try await worker.ping()
        let language = SentenceTiming.alignerLanguage(for: transcription.language) ?? "Chinese"
        let tokens = try await worker.align(
            audioURL: audio,
            text: transcription.text,
            language: language
        )
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertGreaterThan(tokens.last?.endMS ?? 0, tokens.first?.startMS ?? 0)

        let frames = try await FrameExtractor.extract(
            assetURL: video,
            startMS: 0,
            endMS: 6_000,
            destinationDirectory: runDirectory.appending(path: "frames", directoryHint: .isDirectory)
        )
        let representatives = FrameExtractor.representatives(from: frames)
        let ocr = try VisionTextRecognizer.recognize(frames: frames)
        let evidenceText = "ASR: \(transcription.text)\nOCR: \(ocr.map(\.text).joined(separator: " | "))"
        let embedding = try await worker.embed(
            text: evidenceText,
            imageURLs: representatives.map(\.imageURL),
            instruction: "Represent this video moment for semantic retrieval."
        )
        XCTAssertEqual(embedding.dimension, 2_048)
        XCTAssertEqual(embedding.norm, 1, accuracy: 0.001)
        await worker.stop()
    }

    func testRealIndexSearchAndDescriptionClosedLoop() async throws {
        guard ProcessInfo.processInfo.environment["MEDIA_MEMORY_RUN_MODEL_TESTS"] == "1" else {
            throw XCTSkip("设置 MEDIA_MEMORY_RUN_MODEL_TESTS=1 后运行真实模型测试")
        }
        let configuration = try ModelConfiguration.loadDefault()
        let apiKey = try mediaMemorySubkey()
        let video = try testVideoURL()
        let sourceBefore = try FileFingerprint.snapshot(for: video)
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let database = try MediaDatabase(url: temporary.appending(path: "test.sqlite"))
        let rootURL = video.deletingLastPathComponent()
        let root = try await database.addLibraryRoot(path: rootURL.path, bookmark: Data([1]))
        let scan = try await MediaScanner().scan(rootURL: rootURL)
        try await database.applyScan(rootID: root.id, result: scan)
        let assets = try await database.mediaAssets(rootID: root.id)
        let asset = try XCTUnwrap(assets.first { $0.standardizedPath == video.path })

        let workRoot = temporary.appending(path: "Work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let runtime = try LocalModelRuntime(
            configuration: configuration,
            apiKey: apiKey,
            workRoot: workRoot
        )
        let indexer = SegmentIndexer(
            database: database,
            configuration: configuration,
            runtime: runtime,
            workRoot: workRoot
        )
        let summary = try await indexer.runUntilIdle()
        XCTAssertEqual(summary.failed, 0)
        let segments = try await database.segments(assetID: asset.id)
        XCTAssertEqual(summary.succeeded, segments.count)
        let progress = try await database.indexingProgress()
        XCTAssertEqual(progress.succeeded, progress.total)

        let embeddings = try await database.storedEmbeddings(
            modelID: configuration.worker.embeddingModelID,
            inputVersion: SegmentIndexer.inputVersion(for: configuration)
        )
        XCTAssertEqual(embeddings.count, progress.total)
        XCTAssertTrue(embeddings.allSatisfy { $0.values.count == 2_048 })

        let search = SearchService(
            database: database,
            configuration: configuration,
            runtime: runtime
        )
        let query = "视频中的活动"
        let results = try await search.search(query)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.asset.id, asset.id)
        XCTAssertTrue((0..<asset.durationMS).contains(result.playbackStartMS))
        let hotSearchStarted = Date()
        _ = try await search.search(query)
        XCTAssertLessThan(Date().timeIntervalSince(hotSearchStarted), 1.0)

        let descriptions = DescriptionService(
            database: database,
            configuration: configuration,
            runtime: runtime,
            workRoot: workRoot
        )
        let described = try await descriptions.description(segmentID: result.segment.id)
        XCTAssertFalse(described.description.summary.isEmpty)
        let cached = try await descriptions.description(segmentID: result.segment.id)
        XCTAssertEqual(cached, described)
        await runtime.stopDirectModels()

        XCTAssertEqual(try FileFingerprint.snapshot(for: video), sourceBefore)
    }

    private func mediaMemorySubkey() throws -> String {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".omlx/settings.json")
        let data = try Data(contentsOf: settingsURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = root["auth"] as? [String: Any],
              let subkeys = auth["sub_keys"] as? [[String: Any]],
              let record = subkeys.first(where: { $0["name"] as? String == "media-memory" }),
              let key = record["key"] as? String,
              !key.isEmpty else {
            throw XCTSkip("oMLX 中没有名为 media-memory 的子 key")
        }
        return key
    }

    private func testVideoURL() throws -> URL {
        try TestMediaFixture.videoURL()
    }
}
