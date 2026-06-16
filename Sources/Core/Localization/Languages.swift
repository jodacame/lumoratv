import Foundation

/// Comprehensive list of audio/subtitle languages for the global settings, with
/// localized names and the mpv language codes used to match tracks.
enum Languages {
    /// ISO 639-1 codes → ISO 639-2 variants, so mpv matches tracks tagged with
    /// either the 2-letter or the 3-letter code.
    static let iso2: [String: [String]] = [
        "en": ["eng"], "es": ["spa"], "fr": ["fre", "fra"], "de": ["ger", "deu"],
        "it": ["ita"], "pt": ["por"], "nl": ["dut", "nld"], "sv": ["swe"],
        "no": ["nor"], "da": ["dan"], "fi": ["fin"], "is": ["ice", "isl"],
        "pl": ["pol"], "cs": ["cze", "ces"], "sk": ["slo", "slk"], "hu": ["hun"],
        "ro": ["rum", "ron"], "el": ["gre", "ell"], "tr": ["tur"], "ru": ["rus"],
        "uk": ["ukr"], "bg": ["bul"], "sr": ["srp"], "hr": ["hrv"], "sl": ["slv"],
        "he": ["heb"], "ar": ["ara"], "fa": ["per", "fas"], "hi": ["hin"],
        "bn": ["ben"], "ta": ["tam"], "te": ["tel"], "ml": ["mal"], "kn": ["kan"],
        "mr": ["mar"], "ur": ["urd"], "th": ["tha"], "vi": ["vie"], "id": ["ind"],
        "ms": ["may", "msa"], "tl": ["tgl"], "ja": ["jpn"], "ko": ["kor"],
        "zh": ["chi", "zho"], "ca": ["cat"], "eu": ["baq", "eus"], "gl": ["glg"],
        "et": ["est"], "lv": ["lav"], "lt": ["lit"], "af": ["afr"], "sw": ["swa"],
        "am": ["amh"], "fil": ["fil"], "hy": ["arm", "hye"], "ka": ["geo", "kat"],
        "az": ["aze"], "kk": ["kaz"], "uz": ["uzb"], "mn": ["mon"], "ne": ["nep"],
        "si": ["sin"], "km": ["khm"], "lo": ["lao"], "my": ["bur", "mya"],
    ]

    /// All selectable language codes (ISO 639-1), sorted by their localized name.
    static var allCodes: [String] {
        let locale = Locale.current
        return iso2.keys.sorted {
            (name($0, locale: locale)).localizedCaseInsensitiveCompare(name($1, locale: locale)) == .orderedAscending
        }
    }

    /// Localized display name for a code, capitalized (e.g. "Français").
    static func name(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// mpv `alang`/`slang` value for a code: the 2-letter plus its 3-letter forms.
    static func mpvCodes(_ code: String) -> String {
        ([code] + (iso2[code] ?? [])).joined(separator: ",")
    }
}
