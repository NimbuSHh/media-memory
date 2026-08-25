import Foundation
import ImageIO
@preconcurrency import Vision

public struct OCRObservationDraft: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let boxX: Double
    public let boxY: Double
    public let boxWidth: Double
    public let boxHeight: Double
    public let startMS: Int64
    public let endMS: Int64
}

public enum VisionTextRecognizer {
    public static func recognize(frames: [FrameSample]) throws -> [OCRObservationDraft] {
        var observations: [MutableObservation] = []
        for frame in frames {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(frame.imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])

            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else {
                    continue
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    continue
                }
                let box = observation.boundingBox
                let draft = MutableObservation(
                    text: text,
                    normalizedText: normalize(text),
                    confidence: candidate.confidence,
                    box: box,
                    startMS: frame.timeMS,
                    endMS: frame.timeMS + 1_000
                )
                if let index = observations.lastIndex(where: {
                    $0.normalizedText == draft.normalizedText
                        && frame.timeMS - $0.endMS <= 1_500
                        && intersectionOverUnion($0.box, draft.box) >= 0.3
                }) {
                    observations[index].endMS = draft.endMS
                    observations[index].confidence = max(
                        observations[index].confidence,
                        draft.confidence
                    )
                } else {
                    observations.append(draft)
                }
            }
        }
        return observations.map {
            OCRObservationDraft(
                text: $0.text,
                confidence: $0.confidence,
                boxX: $0.box.origin.x,
                boxY: $0.box.origin.y,
                boxWidth: $0.box.width,
                boxHeight: $0.box.height,
                startMS: $0.startMS,
                endMS: $0.endMS
            )
        }
    }

    private struct MutableObservation {
        let text: String
        let normalizedText: String
        var confidence: Float
        let box: CGRect
        let startMS: Int64
        var endMS: Int64
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}
