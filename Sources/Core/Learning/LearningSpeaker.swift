import AVFoundation

/// On-device text-to-speech for the learning mode (pronounce a line/word). Used
/// while paused, so it doesn't fight the movie audio.
@MainActor
final class LearningSpeaker {
    static let shared = LearningSpeaker()
    private let synth = AVSpeechSynthesizer()
    private init() {}

    func speak(_ text: String, lang: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.ttsCode(lang))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        synth.speak(utterance)
    }

    private static func ttsCode(_ lang: String) -> String {
        switch lang.lowercased().prefix(2) {
        case "es": "es-ES"
        case "pt": "pt-BR"
        case "fr": "fr-FR"
        case "de": "de-DE"
        case "it": "it-IT"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        default: "en-US"
        }
    }
}
