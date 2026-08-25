@testable import MediaMemoryCore
import Foundation
import XCTest

final class SemanticVectorIndexTests: XCTestCase {
    func testRanksNormalizedVectorsByCosineSimilarity() {
        let index = SemanticVectorIndex(records: [
            StoredEmbedding(segmentID: "unrelated", values: [0, 1]),
            StoredEmbedding(segmentID: "matching", values: [1, 0]),
            StoredEmbedding(segmentID: "partial", values: [0.6, 0.8])
        ])

        let ranked = index.ranked(query: [1, 0])

        XCTAssertEqual(ranked.map(\.segmentID), ["matching", "partial", "unrelated"])
        XCTAssertEqual(ranked[0].score, 1, accuracy: 0.0001)
        XCTAssertEqual(ranked[1].score, 0.6, accuracy: 0.0001)
        XCTAssertEqual(ranked[2].score, 0, accuracy: 0.0001)
    }

    func testRejectsMismatchedQueryDimension() {
        let index = SemanticVectorIndex(records: [
            StoredEmbedding(segmentID: "segment", values: [1, 0])
        ])
        XCTAssertTrue(index.ranked(query: [1]).isEmpty)
    }

    func testTenThousandVectorHotRankingPerformance() throws {
        guard ProcessInfo.processInfo.environment["MEDIA_MEMORY_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("设置 MEDIA_MEMORY_RUN_PERFORMANCE_TESTS=1 后运行向量性能测试")
        }
        let dimension = 2_048
        let value = Float(1 / sqrt(Double(dimension)))
        let vector = [Float](repeating: value, count: dimension)
        let records = (0..<10_000).map {
            StoredEmbedding(segmentID: "segment-\($0)", values: vector)
        }
        let index = SemanticVectorIndex(records: records)

        let started = Date()
        let ranked = index.ranked(query: vector)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(ranked.count, records.count)
        XCTAssertLessThan(elapsed, 1.0)
    }
}
