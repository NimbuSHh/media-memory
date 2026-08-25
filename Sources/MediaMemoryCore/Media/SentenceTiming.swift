import Foundation

public struct TranscriptSentenceDraft: Equatable, Sendable {
    public let text: String
    public let language: String?
    public let startMS: Int64
    public let endMS: Int64
    public let timingSource: String
}

public enum SentenceTiming {
    private static let supportedLanguages: [String: String] = [
        "zh": "Chinese", "chinese": "Chinese", "mandarin": "Chinese",
        "yue": "Cantonese", "cantonese": "Cantonese",
        "en": "English", "english": "English",
        "fr": "French", "french": "French",
        "de": "German", "german": "German",
        "it": "Italian", "italian": "Italian",
        "ja": "Japanese", "japanese": "Japanese",
        "ko": "Korean", "korean": "Korean",
        "pt": "Portuguese", "portuguese": "Portuguese",
        "ru": "Russian", "russian": "Russian",
        "es": "Spanish", "spanish": "Spanish"
    ]

    public static func alignerLanguage(for detectedLanguage: String?) -> String? {
        guard let detectedLanguage else { return nil }
        return supportedLanguages[detectedLanguage.lowercased()]
    }

    public static func aggregate(
        transcript: String,
        language: String?,
        tokens: [AlignedToken],
        blockStartMS: Int64,
        blockEndMS: Int64
    ) -> [TranscriptSentenceDraft] {
        let sentences = splitSentences(transcript)
        guard !sentences.isEmpty else { return [] }
        guard !tokens.isEmpty else {
            return [
                TranscriptSentenceDraft(
                    text: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                    language: language,
                    startMS: blockStartMS,
                    endMS: blockEndMS,
                    timingSource: "asr_block"
                )
            ]
        }

        var tokenIndex = 0
        var results: [TranscriptSentenceDraft] = []
        for (sentenceIndex, sentence) in sentences.enumerated() {
            let targetLength = max(1, normalizedLength(sentence))
            let firstToken = tokenIndex
            var consumed = 0
            while tokenIndex < tokens.count {
                consumed += max(1, normalizedLength(tokens[tokenIndex].text))
                tokenIndex += 1
                if consumed >= targetLength && sentenceIndex < sentences.count - 1 {
                    break
                }
            }
            guard firstToken < tokenIndex else { continue }
            let localStart = tokens[firstToken].startMS
            let localEnd = tokens[tokenIndex - 1].endMS
            results.append(
                TranscriptSentenceDraft(
                    text: sentence,
                    language: language,
                    startMS: max(blockStartMS, blockStartMS + localStart),
                    endMS: min(blockEndMS, max(blockStartMS + localStart + 1, blockStartMS + localEnd)),
                    timingSource: "forced_alignment_sentence"
                )
            )
        }
        return results
    }

    private static func splitSentences(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        var current = ""
        var sentences: [String] = []
        for character in text {
            current.append(character)
            if terminators.contains(character) {
                let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { sentences.append(value) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }

    private static func normalizedLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }
}
