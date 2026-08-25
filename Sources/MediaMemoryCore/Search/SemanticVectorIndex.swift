import Accelerate
import Foundation

struct SemanticVectorIndex: Sendable {
    let segmentIDs: [String]
    let dimension: Int
    private let matrix: [Float]

    init(records: [StoredEmbedding]) {
        let expectedDimension = records.first?.values.count ?? 0
        dimension = expectedDimension
        let valid = records.filter {
            !$0.values.isEmpty && $0.values.count == expectedDimension
        }
        segmentIDs = valid.map(\.segmentID)
        matrix = valid.flatMap(\.values)
    }

    func ranked(query: [Float]) -> [(segmentID: String, score: Double)] {
        guard dimension > 0,
              query.count == dimension,
              !segmentIDs.isEmpty else { return [] }
        var scores = [Float](repeating: 0, count: segmentIDs.count)
        matrix.withUnsafeBufferPointer { matrixBuffer in
            query.withUnsafeBufferPointer { queryBuffer in
                guard let matrixBase = matrixBuffer.baseAddress else { return }
                for row in segmentIDs.indices {
                    let vector = UnsafeBufferPointer(
                        start: matrixBase.advanced(by: row * dimension),
                        count: dimension
                    )
                    scores[row] = vDSP.dot(vector, queryBuffer)
                }
            }
        }
        return zip(segmentIDs, scores)
            .map { ($0.0, Double(min(1, max(-1, $0.1)))) }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                return lhs.1 > rhs.1
            }
    }
}
