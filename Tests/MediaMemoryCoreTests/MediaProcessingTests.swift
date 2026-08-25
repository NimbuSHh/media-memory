import Foundation
@testable import MediaMemoryCore
import XCTest

final class MediaProcessingTests: XCTestCase {
    func testAudioAndFramesUseSourceTimeWithoutChangingVideo() async throws {
        let video = try testVideoURL()
        let before = try FileFingerprint.snapshot(for: video)
        let temporary = try ProcessingTemporaryDirectory()
        let audio = temporary.url.appending(path: "sample.wav")
        let framesDirectory = temporary.url.appending(path: "frames", directoryHint: .isDirectory)

        _ = try await AudioSegmentExtractor.extractWAV(
            assetURL: video,
            startMS: 0,
            endMS: 6_000,
            destinationURL: audio
        )
        let frames = try await FrameExtractor.extract(
            assetURL: video,
            startMS: 0,
            endMS: 6_000,
            destinationDirectory: framesDirectory
        )
        let after = try FileFingerprint.snapshot(for: video)

        XCTAssertEqual(after, before)
        XCTAssertGreaterThan(try Data(contentsOf: audio).count, 44)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { (0..<6_000).contains($0.timeMS) })
        XCTAssertLessThanOrEqual(FrameExtractor.representatives(from: frames).count, 8)
        _ = try VisionTextRecognizer.recognize(frames: frames)
    }

    func testSentenceAggregationProducesSentenceRanges() {
        let tokens = [
            AlignedToken(text: "你好", startMS: 100, endMS: 500),
            AlignedToken(text: "。", startMS: 500, endMS: 600),
            AlignedToken(text: "出发", startMS: 900, endMS: 1_300),
            AlignedToken(text: "！", startMS: 1_300, endMS: 1_400)
        ]

        let sentences = SentenceTiming.aggregate(
            transcript: "你好。出发！",
            language: "Chinese",
            tokens: tokens,
            blockStartMS: 20_000,
            blockEndMS: 40_000
        )

        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].text, "你好。")
        XCTAssertEqual(sentences[0].startMS, 20_100)
        XCTAssertEqual(sentences[0].endMS, 20_600)
        XCTAssertEqual(sentences[1].startMS, 20_900)
        XCTAssertEqual(sentences[1].endMS, 21_400)
    }

    private func testVideoURL() throws -> URL {
        try TestMediaFixture.videoURL()
    }
}

private final class ProcessingTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-processing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
