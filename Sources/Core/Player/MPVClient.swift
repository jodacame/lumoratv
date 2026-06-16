import Foundation
import QuartzCore
import UIKit
import Libmpv

struct MPVTrack: Identifiable, Hashable, Sendable {
    let id: Int
    let type: String      // "audio" | "sub"
    let title: String?
    let lang: String?
    let codec: String?
    let channels: Int?
    let selected: Bool
    /// true for tracks added at runtime (sidecar/OpenSubtitles), false for
    /// tracks embedded in the container.
    var external: Bool = false

    var displayName: String {
        var parts: [String] = []
        if let lang {
            parts.append(Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang.uppercased())
        }
        if let title, !parts.contains(title) {
            parts.append(title)
        }
        if let codec {
            var codecLabel = codec.uppercased()
            if codecLabel.contains("TRUEHD") { codecLabel = "TrueHD" }
            if let channels {
                let layout = switch channels {
                case 8: "7.1"
                case 6: "5.1"
                case 2: "2.0"
                default: "\(channels)ch"
                }
                codecLabel += " \(layout)"
            }
            parts.append(codecLabel)
        }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }
}

/// Swift 6-safe libmpv wrapper.
/// The mpv handle is thread-safe; events are drained on a dedicated queue
/// and delivered on the main thread.
final class MPVClient: @unchecked Sendable {

    enum Event: Sendable {
        case timePos(Double)
        case duration(Double)
        case paused(Bool)
        case buffering(Bool)
        case fileLoaded
        case endOfFile
        /// Playback failed. Carries a human-readable detail (mpv error string
        /// and/or the latest error-level log line) when one is available.
        case playbackError(String?)
        case sigPeak(Double)
        case videoParams(width: Int, height: Int)
        /// Current primary subtitle line (learning mode draws it itself).
        case subText(String)
        /// Current secondary subtitle line (native language, learning mode).
        case secondarySubText(String)
    }

    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "lumoratv.mpv.events", qos: .userInitiated)
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var attachedLayer: CAMetalLayer?
    /// Latest error/fatal log line from mpv (drained on `eventQueue`), used to
    /// give the failure overlay a concrete reason (e.g. "Failed to open URL").
    private var lastErrorText: String?

    // MARK: Setup

    func start(
        layer: CAMetalLayer,
        url: URL,
        startSeconds: Double,
        audioLang: String? = nil,     // mpv codes, e.g. "spa,es"
        subtitleLang: String? = nil,  // mpv codes, or nil = no subtitles
        passthrough: Bool = false,    // experimental: bitstream AC3/E-AC3 to the AO
        muted: Bool = false,          // card preview: no audio
        loop: Bool = false,           // card preview: repeats
        networkStream: Bool = false,  // torrent/HTTP: aggressive anti-stall buffering
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        guard mpv == nil, let handle = mpv_create() else { return }
        eventHandler = onEvent
        attachedLayer = layer
        mpv = handle

        // Audio output: prefer avfoundation (AVSampleBufferAudioRenderer) — it's
        // managed by the OS and works on routes where the raw audiounit output
        // can't open (e.g. HDMI routes that report 32 channels on Apple TV 4K
        // 3rd gen / tvOS 26.x). Falls back to audiounit if avfoundation can't
        // initialize (e.g. SPDIF/passthrough, which avfoundation doesn't handle).
        opt("ao", "avfoundation,audiounit")

        // Render: gpu-next (libplacebo) on Metal via MoltenVK.
        opt("vo", "gpu-next")
        opt("gpu-api", "vulkan")
        opt("gpu-context", "moltenvk")
        opt("hwdec", "videotoolbox")

        if muted { opt("mute", "yes") }
        if loop { opt("loop-file", "inf") }

        // Multichannel audio: use the layout the session exposes (5.1/7.1 with AVAudioSession).
        opt("audio-channels", "auto-safe")
        if passthrough {
            // If the AO does not accept the bitstream, mpv falls back to decoding automatically.
            opt("audio-spdif", "ac3,eac3")
        }
        // HDR passthrough/EDR: must be set before initialization.
        opt("target-colorspace-hint", "yes")
        opt("video-rotate", "no")

        // User-preferred languages.
        if let audioLang {
            opt("alang", audioLang)
        }
        if let subtitleLang {
            opt("slang", subtitleLang)
            opt("subs-fallback", "yes")
        } else {
            // No subtitles by default (tracks remain available in the panel).
            opt("sid", "no")
        }

        // Subtitles (libass).
        opt("sub-font-size", "42")

        // Generous cache for 4K remux over the local network.
        opt("cache", "yes")
        if networkStream {
            // Torrent/HTTP: large readahead + resume with headroom to avoid
            // micro-stalls. Builds up buffer before starting and before resuming after draining.
            opt("demuxer-max-bytes", "512MiB")
            opt("demuxer-max-back-bytes", "128MiB")
            opt("demuxer-readahead-secs", "120")
            opt("cache-secs", "120")
            opt("cache-pause", "yes")             // pause when the buffer drains (instead of stuttering)
            opt("cache-pause-wait", "6")          // wait for 6s of data before resuming
            opt("cache-pause-initial", "yes")     // wait for the initial buffer before starting
        } else {
            opt("demuxer-max-bytes", "256MiB")
            opt("demuxer-max-back-bytes", "64MiB")
            opt("demuxer-readahead-secs", "30")
        }

        opt("keep-open", "yes")
        opt("idle", "yes")

        if startSeconds > 1 {
            opt("start", String(Int(startSeconds)))
        }

        // Capture error-level logs (always): they carry the concrete reason a
        // stream fails to open, which we surface on the failure overlay.
        #if DEBUG
        mpv_request_log_messages(handle, "warn")
        #else
        mpv_request_log_messages(handle, "error")
        #endif

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)

        mpv_initialize(handle)

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("video-params/sig-peak", MPV_FORMAT_DOUBLE)
        observe("sub-text", MPV_FORMAT_STRING)
        observe("secondary-sub-text", MPV_FORMAT_STRING)

        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVClient>.fromOpaque(ctx).takeUnretainedValue().pump()
        }, Unmanaged.passUnretained(self).toOpaque())

        command("loadfile", [url.absoluteString, "replace"])
    }

    /// Stops and releases mpv synchronously. Call exactly once when closing the player.
    func shutdown() {
        guard let handle = mpv else { return }
        mpv = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        eventQueue.sync { } // wait for the in-flight drain to finish
        mpv_terminate_destroy(handle)
        attachedLayer = nil
        eventHandler = nil
    }

    // MARK: Controls

    func setPause(_ paused: Bool) {
        var value: Int32 = paused ? 1 : 0
        guard let handle = mpv else { return }
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &value)
    }

    func seek(by seconds: Double) {
        command("seek", [String(seconds), "relative+exact"])
    }

    func seek(to seconds: Double) {
        command("seek", [String(seconds), "absolute+exact"])
    }

    /// Keyframe-based seek: fast, for scan mode (2x/4x/8x…).
    func seekFast(to seconds: Double) {
        command("seek", [String(seconds), "absolute+keyframes"])
    }

    func setAudioTrack(_ id: Int) {
        setString("aid", String(id))
    }

    /// Subtitle style, applicable on the fly.
    /// Forces the override over embedded ASS styles and always re-wraps (never truncates).
    func applySubtitleStyle(fontSize: String, font: String?, colorHex: String) {
        setString("sub-ass-override", "force")
        setString("sub-ass-style-overrides", "WrapStyle=0")
        setString("sub-font-size", fontSize)
        setString("sub-font", font ?? "sans-serif")
        setString("sub-color", colorHex)
        setString("sub-border-size", "2.5")
        // Side margin so wrapped text respects the TV safe area.
        setString("sub-margin-x", "140")
        setString("sub-use-margins", "yes")
    }

    func setSubtitleTrack(_ id: Int?) {
        setString("sid", id.map(String.init) ?? "no")
    }

    /// Re-selects the currently active subtitle track to force mpv to re-read it
    /// from the demuxer at the current position. Embedded subtitles streamed over
    /// the network (TorrServer) can silently stop rendering after a cache
    /// underrun until the track is toggled; this replicates that manual fix.
    /// No-op when no subtitle is selected.
    func reselectSubtitle() {
        guard let sid = getString("sid"), sid != "no", sid != "auto" else { return }
        setString("sid", "no")
        setString("sid", sid)
    }

    /// Secondary subtitle track (shown together with the primary; used by the
    /// learning mode to expose the native-language line via `secondary-sub-text`).
    func setSecondarySubtitleTrack(_ id: Int?) {
        setString("secondary-sid", id.map(String.init) ?? "no")
    }

    /// Hide/show mpv's own subtitle rendering. Learning mode hides it and draws a
    /// styled overlay itself (the text is still exposed via `sub-text`).
    func setSubtitleVisibility(_ visible: Bool) {
        setString("sub-visibility", visible ? "yes" : "no")
        setString("secondary-sub-visibility", visible ? "yes" : "no")
    }

    /// Raises the subtitles while the bottom transport is visible so they clear
    /// the controls (`sub-pos`: 100 = bottom, lower = higher). The control stack
    /// reaches ~25% up, so the raised position sits above it.
    func setSubtitlePosition(raised: Bool) {
        setString("sub-pos", raised ? "72" : "100")
    }

    /// Picture mode via the video equalizer (works with gpu-next). "sleep" softens
    /// and dims the image to relax the eyes; "vivid" makes colors pop; "normal"
    /// resets everything.
    func applyColorMode(_ mode: String) {
        let (saturation, brightness, contrast, gamma): (Int, Int, Int, Int)
        switch mode {
        case "sleep": (saturation, brightness, contrast, gamma) = (-30, -10, -6, -6)
        case "vivid": (saturation, brightness, contrast, gamma) = (28, 3, 12, 0)
        case "noir":  (saturation, brightness, contrast, gamma) = (-100, -2, 10, 0)  // full grayscale, classic-film contrast
        default:      (saturation, brightness, contrast, gamma) = (0, 0, 0, 0)
        }
        setString("saturation", String(saturation))
        setString("brightness", String(brightness))
        setString("contrast", String(contrast))
        setString("gamma", String(gamma))
    }

    /// Adds an external subtitle (does not select it).
    func addSubtitle(url: URL, title: String?, lang: String?) {
        command("sub-add", [url.absoluteString, "auto", title ?? "", lang ?? ""])
    }

    /// Adds an external subtitle and selects it immediately.
    func addAndSelectSubtitle(url: URL, title: String?, lang: String?) {
        command("sub-add", [url.absoluteString, "select", title ?? "", lang ?? ""])
    }

    /// Loads another file in the same player (next episode / source switch).
    func loadFile(url: URL) {
        // The initial open may have set a global `start` position (resume). mpv
        // would re-apply it to this new file, making it begin at the PREVIOUS
        // file's offset. Reset it so the new file starts at 0; any resume for the
        // new file is applied via an explicit seek once it loads.
        setString("start", "0")
        command("loadfile", [url.absoluteString, "replace"])
    }


    var timePos: Double { getDouble("time-pos") }

    struct MPVChapter: Identifiable, Sendable, Equatable {
        let index: Int
        let title: String?
        let time: Double
        var id: Int { index }
    }

    /// Chapters in the file (mpv reads them from the container, e.g. MKV).
    func chapters() -> [MPVChapter] {
        struct RawChapter: Decodable {
            let title: String?
            let time: Double
        }
        guard let json = getString("chapter-list"),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawChapter].self, from: data) else { return [] }
        return raw.enumerated().map { MPVChapter(index: $0.offset, title: $0.element.title, time: $0.element.time) }
    }

    // MARK: Tracks

    private struct RawTrack: Decodable {
        let id: Int
        let type: String
        let title: String?
        let lang: String?
        let codec: String?
        let selected: Bool?
        let external: Bool?
        let demuxChannelCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, type, title, lang, codec, selected, external
            case demuxChannelCount = "demux-channel-count"
        }
    }

    func tracks() -> [MPVTrack] {
        guard let json = getString("track-list"),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawTrack].self, from: data) else { return [] }
        return raw
            .filter { $0.type == "audio" || $0.type == "sub" }
            .map {
                MPVTrack(
                    id: $0.id,
                    type: $0.type,
                    title: $0.title,
                    lang: $0.lang,
                    codec: $0.codec,
                    channels: $0.demuxChannelCount,
                    selected: $0.selected ?? false,
                    external: $0.external ?? false
                )
            }
    }

    // MARK: Events

    private func pump() {
        eventQueue.async { [weak self] in
            self?.drainEvents()
        }
    }

    private func drainEvents() {
        while let handle = mpv {
            guard let event = mpv_wait_event(handle, 0) else { break }
            let eventID = event.pointee.event_id
            if eventID == MPV_EVENT_NONE { break }

            switch eventID {
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event)
            case MPV_EVENT_LOG_MESSAGE:
                handleLogMessage(event)
            case MPV_EVENT_FILE_LOADED:
                lastErrorText = nil
                emit(.fileLoaded)
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if endFile.reason == MPV_END_FILE_REASON_EOF {
                        emit(.endOfFile)
                    } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                        emit(.playbackError(failureDetail(errorCode: endFile.error)))
                    }
                }
            case MPV_EVENT_SHUTDOWN:
                mpv = nil
            default:
                break
            }
        }
    }

    /// Keeps the latest error/fatal log line so a failure can report a reason.
    private func handleLogMessage(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else { return }
        let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
        let level = String(cString: msg.level)
        let prefix = String(cString: msg.prefix)
        let text = String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        #if DEBUG
        // Mirror to the device console so it can be captured remotely
        // (devicectl process launch --console).
        print("[mpv][\(level)] \(prefix): \(text)")
        #endif
        guard level == "error" || level == "fatal" else { return }
        // Skip noisy, non-actionable lines so the overlay shows the real cause.
        let lowered = text.lowercased()
        guard !lowered.contains("could not open codec"),
              !lowered.contains("hardware decoding") else { return }
        lastErrorText = "\(prefix): \(text)"
    }

    /// Builds a human-readable failure detail from mpv's error code plus the
    /// most recent error log line (which usually names the URL/HTTP status).
    private func failureDetail(errorCode: Int32) -> String? {
        var parts: [String] = []
        if let log = lastErrorText, !log.isEmpty {
            parts.append(log)
        }
        if errorCode != 0, let cstr = mpv_error_string(errorCode) {
            let reason = String(cString: cstr)
            if !reason.isEmpty, !parts.contains(where: { $0.localizedCaseInsensitiveContains(reason) }) {
                parts.append(reason)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        let name = String(cString: property.name)

        switch name {
        case "time-pos":
            if let value = doubleValue(property) { emit(.timePos(value)) }
        case "duration":
            if let value = doubleValue(property) { emit(.duration(value)) }
        case "pause":
            if let value = flagValue(property) { emit(.paused(value)) }
        case "paused-for-cache":
            if let value = flagValue(property) { emit(.buffering(value)) }
        case "eof-reached":
            if flagValue(property) == true { emit(.endOfFile) }
        case "video-params/sig-peak":
            if let value = doubleValue(property) { emit(.sigPeak(value)) }
        case "sub-text":
            emit(.subText(stringValue(property) ?? ""))
        case "secondary-sub-text":
            emit(.secondarySubText(stringValue(property) ?? ""))
        default:
            break
        }
    }

    private func stringValue(_ property: mpv_event_property) -> String? {
        guard property.format == MPV_FORMAT_STRING, let data = property.data else { return nil }
        guard let cstr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
        return String(cString: cstr)
    }

    private func doubleValue(_ property: mpv_event_property) -> Double? {
        guard property.format == MPV_FORMAT_DOUBLE, let data = property.data else { return nil }
        return data.assumingMemoryBound(to: Double.self).pointee
    }

    private func flagValue(_ property: mpv_event_property) -> Bool? {
        guard property.format == MPV_FORMAT_FLAG, let data = property.data else { return nil }
        return data.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    private func emit(_ event: Event) {
        guard let handler = eventHandler else { return }
        DispatchQueue.main.async {
            handler(event)
        }
    }

    // MARK: Helpers

    private func opt(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        mpv_set_option_string(handle, name, value)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func getString(_ name: String) -> String? {
        guard let handle = mpv else { return nil }
        guard let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private func getDouble(_ name: String) -> Double {
        guard let handle = mpv else { return 0 }
        var value = Double()
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    // MARK: Stats for nerds

    /// Live technical snapshot for the diagnostics overlay.
    struct NerdStats: Sendable, Equatable {
        var videoCodec = ""
        var resolution = ""
        var height = 0              // for a friendly quality label (1080p/4K)
        var fps = 0.0               // actually rendered on screen
        var containerFps = 0.0      // declared by the file (24, 23.976, 25, 60…)
        var isHDR = false
        var videoBitrateMbps = 0.0
        var hwdec = ""
        var audioCodec = ""
        // Real audio OUTPUT sent to the device (not the source format).
        var audioOutChannels = 0
        var audioOutLayout = ""     // "5.1", "stereo"…
        var audioOutFormat = ""     // "float", "s16"…
        var audioOutSampleRate = 0
        var ao = ""                 // active output: "avfoundation" / "audiounit"
        var droppedFrames = 0
        var cacheSeconds = 0.0
        var cacheSpeedMbps = 0.0
    }

    func nerdStats() -> NerdStats {
        var s = NerdStats()
        s.videoCodec = getString("video-codec") ?? ""
        let w = Int(getDouble("video-params/w")), h = Int(getDouble("video-params/h"))
        if w > 0 { s.resolution = "\(w)×\(h)" }
        s.height = h
        s.fps = getDouble("estimated-vf-fps")
        s.containerFps = getDouble("container-fps")
        s.isHDR = getDouble("video-params/sig-peak") > 1.0
        s.videoBitrateMbps = getDouble("video-bitrate") / 1_000_000
        s.audioCodec = getString("audio-codec-name")?.uppercased() ?? ""
        s.hwdec = getString("hwdec-current") ?? ""
        // Real output format (post-decode, what actually reaches the device).
        s.audioOutChannels = Int(getDouble("audio-out-params/channel-count"))
        s.audioOutLayout = getString("audio-out-params/hr-channels")
            ?? getString("audio-out-params/channels") ?? ""
        s.audioOutFormat = getString("audio-out-params/format") ?? ""
        s.audioOutSampleRate = Int(getDouble("audio-out-params/samplerate"))
        s.ao = getString("current-ao") ?? ""
        s.droppedFrames = Int(getDouble("frame-drop-count"))
        s.cacheSeconds = getDouble("demuxer-cache-duration")
        s.cacheSpeedMbps = getDouble("cache-speed") * 8 / 1_000_000
        return s
    }

    // MARK: Frame-rate matching

    /// The content's declared frame rate and dynamic range, for matching the
    /// Apple TV's HDMI output (see `FrameRateMatcher`). Returns nil until the
    /// file is loaded and the video params are known, or for invalid fps.
    func frameRateMatch() -> (refreshRate: Double, dynamicRange: FrameRateMatcher.DynamicRange)? {
        let fps = getDouble("container-fps")
        guard fps > 1, fps < 1000 else { return nil }
        let transfer = (getString("video-params/gamma") ?? "").lowercased()
        let dynamicRange: FrameRateMatcher.DynamicRange
        if transfer.contains("pq") {
            dynamicRange = .hdr10
        } else if transfer.contains("hlg") {
            dynamicRange = .hlg
        } else if getDouble("video-params/sig-peak") > 1.0 {
            dynamicRange = .hdr10            // HDR signaled without a known transfer name
        } else {
            dynamicRange = .sdr
        }
        return (fps, dynamicRange)
    }

    private func observe(_ name: String, _ format: mpv_format) {
        guard let handle = mpv else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    private func command(_ name: String, _ args: [String]) {
        guard let handle = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = []
        cargs.append(UnsafePointer(strdup(name)))
        for arg in args {
            cargs.append(UnsafePointer(strdup(arg)))
        }
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr))
            }
        }
        mpv_command(handle, &cargs)
    }
}
