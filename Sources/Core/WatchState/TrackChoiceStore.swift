import Foundation

/// Remembers the audio / subtitle the user picked for a piece of content, so
/// resuming ("continue watching") restores them. Stored by normalized language
/// (track ids aren't stable across sessions, especially for torrents/external
/// subs). For episodes a per-show entry is also kept, so the choice carries
/// across the season during a binge.
enum TrackChoiceStore {
    private static let subStore = "trackChoice.sub"
    private static let audioStore = "trackChoice.audio"
    private static var defaults: UserDefaults { .standard }

    /// `value`: a normalized 2-letter language ("es"/"en"…), or "off" for
    /// subtitles explicitly disabled; nil clears the entry.
    static func saveSubtitle(_ value: String?, userID: String, keys: [String]) {
        write(subStore, value, userID: userID, keys: keys)
    }
    static func saveAudio(_ value: String?, userID: String, keys: [String]) {
        write(audioStore, value, userID: userID, keys: keys)
    }
    static func subtitle(userID: String, keys: [String]) -> String? {
        read(subStore, userID: userID, keys: keys)
    }
    static func audio(userID: String, keys: [String]) -> String? {
        read(audioStore, userID: userID, keys: keys)
    }

    private static func write(_ store: String, _ value: String?, userID: String, keys: [String]) {
        var dict = defaults.dictionary(forKey: store) as? [String: String] ?? [:]
        for key in keys {
            let k = "\(userID)|\(key)"
            if let value { dict[k] = value } else { dict.removeValue(forKey: k) }
        }
        defaults.set(dict, forKey: store)
    }

    private static func read(_ store: String, userID: String, keys: [String]) -> String? {
        let dict = defaults.dictionary(forKey: store) as? [String: String] ?? [:]
        for key in keys where dict["\(userID)|\(key)"] != nil {
            return dict["\(userID)|\(key)"]
        }
        return nil
    }
}
