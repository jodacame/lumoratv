import AVFAudio

/// Configures the audio session for true multichannel output (5.1/7.1 LPCM to the receiver).
/// Without this, tvOS limits output to stereo and mpv downmixes.
enum AudioSession {
    static func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            // Request a real consumer surround layout (up to 7.1). Note: some
            // HDMI routes (e.g. Apple TV 4K 3rd gen on tvOS 26.5) report a
            // 32-channel output that tvOS won't let an app reduce, and mpv's
            // audio engine can't map more than 16 channels — those routes stay
            // silent regardless of what we set here. That's an mpv/MPVKit
            // limitation, not something this layer can work around.
            let channels = min(session.maximumOutputNumberOfChannels, 8)
            if channels > 2 {
                try session.setPreferredOutputNumberOfChannels(channels)
            }
        } catch {
            // Playback continues with the default configuration.
        }
    }
}
