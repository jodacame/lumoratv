import Foundation
import NaturalLanguage

/// Breaks a subtitle line into renderable segments (preserving spaces/punctuation),
/// flagging the content words (nouns/verbs/adjectives/adverbs) that the learner
/// hasn't mastered yet so the UI can highlight exactly those — all on-device.
enum SubtitleAnalyzer {
    struct Segment: Identifiable {
        let id = UUID()
        let text: String
        let highlight: Bool   // a new/learning content word
    }

    private static let contentTags: Set<NLTag> = [.noun, .verb, .adjective, .adverb]

    /// Splits a line into its words (for the selectable word chips in the recall).
    static func words(_ line: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = line
        var words: [String] = []
        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
            let w = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !w.isEmpty { words.append(w) }
            return true
        }
        return words
    }

    /// Maps a subtitle language tag ("en"/"eng"/"es"/"spa"…) to an NLLanguage.
    static func nlLanguage(_ lang: String?) -> NLLanguage? {
        guard let l = lang?.lowercased(), !l.isEmpty else { return nil }
        let map: [String: NLLanguage] = [
            "en": .english, "eng": .english, "es": .spanish, "spa": .spanish,
            "pt": .portuguese, "por": .portuguese, "fr": .french, "fre": .french, "fra": .french,
            "de": .german, "ger": .german, "deu": .german, "it": .italian, "ita": .italian,
            "ja": .japanese, "jpn": .japanese, "ko": .korean, "kor": .korean,
        ]
        return map[l] ?? map[String(l.prefix(2))]
    }

    /// Returns the styled segments of `line` plus the content lemmas it contains
    /// (for recording encounters). `isHighlighted(lemma)` decides which to emphasize.
    static func segments(
        line: String,
        language: NLLanguage?,
        isHighlighted: (String) -> Bool
    ) -> (segments: [Segment], lemmas: [String]) {
        guard !line.isEmpty else { return ([], []) }
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = line
        if let language { tagger.setLanguage(language, range: line.startIndex..<line.endIndex) }

        var segs: [Segment] = []
        var lemmas: [String] = []
        var cursor = line.startIndex

        tagger.enumerateTags(in: line.startIndex..<line.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace]) { tag, range in
            if cursor < range.lowerBound {
                segs.append(Segment(text: String(line[cursor..<range.lowerBound]), highlight: false))
            }
            let text = String(line[range])
            var highlight = false
            if let tag, contentTags.contains(tag) {
                let lemma = (tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? text).lowercased()
                lemmas.append(lemma)
                highlight = isHighlighted(lemma)
            }
            segs.append(Segment(text: text, highlight: highlight))
            cursor = range.upperBound
            return true
        }
        if cursor < line.endIndex {
            segs.append(Segment(text: String(line[cursor...]), highlight: false))
        }
        return (segs, lemmas)
    }
}
