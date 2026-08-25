@testable import MediaMemoryCore
import XCTest

final class SemanticSegmentPlannerTests: XCTestCase {
    private let planner = SemanticSegmentPlanner()

    func testShortVideoIsOneCompleteSegment() {
        let segments = planner.plan(
            SemanticSegmentationInput(
                durationMS: 3_500,
                boundaryCandidates: [
                    .init(timeMS: 1_000, source: .shotChange, score: 1)
                ]
            )
        )

        XCTAssertEqual(
            segments,
            [
                PlannedSemanticSegment(
                    ordinal: 0,
                    startMS: 0,
                    endMS: 3_500,
                    endBoundarySources: []
                )
            ]
        )
    }

    func testFastCutsAreMergedIntoTargetSizedSemanticSegments() {
        let cuts = stride(from: Int64(1_000), to: 30_000, by: 1_000).map {
            SemanticBoundaryCandidate(timeMS: $0, source: .shotChange, score: 1)
        }

        let segments = planner.plan(
            SemanticSegmentationInput(durationMS: 30_000, boundaryCandidates: cuts)
        )

        XCTAssertEqual(segments.map(\.startMS), [0, 11_000, 22_000])
        XCTAssertEqual(segments.map(\.endMS), [11_000, 22_000, 30_000])
        XCTAssertEqual(segments[0].endBoundarySources, [.shotChange])
        assertValidTimeline(segments, durationMS: 30_000)
    }

    func testLongShotUsesHardMaximumAndAvoidsTinyTail() {
        let segments = planner.plan(
            SemanticSegmentationInput(durationMS: 62_000, boundaryCandidates: [])
        )

        XCTAssertEqual(segments.map(\.startMS), [0, 30_000, 46_000])
        XCTAssertEqual(segments.map(\.endMS), [30_000, 46_000, 62_000])
        XCTAssertTrue(segments.allSatisfy { $0.endBoundarySources.isEmpty })
        assertValidTimeline(segments, durationMS: 62_000)
    }

    func testNoAudioCanUseShotAndOCRBoundaries() {
        let segments = planner.plan(
            SemanticSegmentationInput(
                durationMS: 30_000,
                boundaryCandidates: [
                    .init(timeMS: 9_000, source: .shotChange, score: 0.9),
                    .init(timeMS: 24_000, source: .ocrChange, score: 1)
                ]
            )
        )

        XCTAssertEqual(segments.map(\.endMS), [9_000, 24_000, 30_000])
        XCTAssertEqual(segments[0].endBoundarySources, [.shotChange])
        XCTAssertEqual(segments[1].endBoundarySources, [.ocrChange])
        assertValidTimeline(segments, durationMS: 30_000)
    }

    func testSentenceAndPauseCanDriveLongStaticVideo() {
        let segments = planner.plan(
            SemanticSegmentationInput(
                durationMS: 34_000,
                boundaryCandidates: [
                    .init(timeMS: 10_000, source: .sentenceEnd),
                    .init(timeMS: 21_000, source: .pause, score: 0.9)
                ]
            )
        )

        XCTAssertEqual(segments.map(\.endMS), [10_000, 21_000, 34_000])
        assertValidTimeline(segments, durationMS: 34_000)
    }

    func testSparseCandidatesChooseStrongestBoundaryNearHardLimit() {
        let segments = planner.plan(
            SemanticSegmentationInput(
                durationMS: 50_000,
                boundaryCandidates: [
                    .init(timeMS: 26_000, source: .shotChange, score: 0.4),
                    .init(timeMS: 28_500, source: .shotChange, score: 0.95)
                ]
            )
        )

        XCTAssertEqual(segments.map(\.endMS), [28_500, 50_000])
        assertValidTimeline(segments, durationMS: 50_000)
    }

    func testNearbySignalsMergeAndCandidateOrderDoesNotAffectPlan() {
        let candidates: [SemanticBoundaryCandidate] = [
            .init(timeMS: 11_100, source: .sentenceEnd, score: 0.8),
            .init(timeMS: 10_950, source: .ocrChange, score: 0.9),
            .init(timeMS: 11_000, source: .shotChange, score: 0.7),
            .init(timeMS: 22_000, source: .pause, score: 0.8),
            .init(timeMS: 22_000, source: .pause, score: 0.3),
            .init(timeMS: -1, source: .shotChange, score: 1),
            .init(timeMS: 100_000, source: .shotChange, score: 1)
        ]
        let input = SemanticSegmentationInput(
            durationMS: 30_000,
            boundaryCandidates: candidates
        )
        let reversedInput = SemanticSegmentationInput(
            durationMS: 30_000,
            boundaryCandidates: Array(candidates.reversed())
        )

        let first = planner.plan(input)
        let second = planner.plan(reversedInput)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.endMS), [11_100, 22_000, 30_000])
        XCTAssertEqual(
            first[0].endBoundarySources,
            [.shotChange, .sentenceEnd, .ocrChange]
        )
        assertValidTimeline(first, durationMS: 30_000)
    }

    func testInvalidAndWeakCandidatesStillProduceACompleteTimeline() {
        let segments = planner.plan(
            SemanticSegmentationInput(
                durationMS: 35_000,
                boundaryCandidates: [
                    .init(timeMS: 12_000, source: .shotChange, score: .nan),
                    .init(timeMS: 13_000, source: .ocrChange, score: 0.1),
                    .init(timeMS: 16_000, source: .pause, score: -1)
                ]
            )
        )

        XCTAssertEqual(segments.map(\.endMS), [17_500, 35_000])
        assertValidTimeline(segments, durationMS: 35_000)
    }

    func testNonPositiveDurationProducesNoSegments() {
        XCTAssertEqual(
            planner.plan(SemanticSegmentationInput(durationMS: 0, boundaryCandidates: [])),
            []
        )
    }

    private func assertValidTimeline(
        _ segments: [PlannedSemanticSegment],
        durationMS: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(segments.isEmpty, file: file, line: line)
        XCTAssertEqual(segments.first?.startMS, 0, file: file, line: line)
        XCTAssertEqual(segments.last?.endMS, durationMS, file: file, line: line)
        XCTAssertEqual(segments.map(\.ordinal), Array(segments.indices), file: file, line: line)
        XCTAssertTrue(
            segments.allSatisfy {
                $0.endMS > $0.startMS && $0.endMS - $0.startMS <= 30_000
            },
            file: file,
            line: line
        )
        if durationMS >= 4_000 {
            XCTAssertTrue(
                segments.allSatisfy { $0.endMS - $0.startMS >= 4_000 },
                file: file,
                line: line
            )
        }
        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(pair.0.endMS, pair.1.startMS, file: file, line: line)
        }
    }
}
