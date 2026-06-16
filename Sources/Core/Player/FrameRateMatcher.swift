import UIKit
import AVKit

/// Matches the Apple TV's HDMI output mode to the content being played, so 24p
/// (23.976/24 fps) material stops juddering against a fixed 60 Hz output (the
/// classic 3:2 cadence). This is what Netflix / Infuse / VLC do; tvOS only does
/// it automatically for AVPlayer-based playback, and we render with libmpv, so
/// we must drive `AVDisplayManager` ourselves.
///
/// `AVDisplayCriteria` has no public initializer, so we call the SPI one declared
/// in the bridging header — but ONLY after confirming at runtime that the class
/// actually exposes that selector. If a future tvOS renames/removes it, every
/// call degrades to a silent no-op instead of crashing the player.
///
/// The switch also only happens when the user has *Settings → Video and Audio →
/// Match Content → Match Frame Rate* enabled (`isDisplayCriteriaMatchingEnabled`).
@MainActor
enum FrameRateMatcher {
    /// Dynamic-range codes understood by the `AVDisplayCriteria` SPI initializer.
    enum DynamicRange: Int32 {
        case sdr = 0
        case hdr10 = 2   // PQ / ST.2084
        case hlg = 3
    }

    /// Whether the runtime exposes `-[AVDisplayCriteria initWithRefreshRate:videoDynamicRange:]`.
    /// Evaluated once; guards every SPI call so a missing selector can't crash.
    private static let spiAvailable: Bool = AVDisplayCriteria.instancesRespond(
        to: NSSelectorFromString("initWithRefreshRate:videoDynamicRange:")
    )

    /// The display manager of the active foreground window (where the player lives).
    private static var displayManager: AVDisplayManager? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first?
            .avDisplayManager
    }

    /// Switches the output to `refreshRate` Hz with the given dynamic range.
    /// No-op when the SPI is unavailable, the fps is unknown, the device/display
    /// can't match, or the user has Match Content disabled. Re-calling with the
    /// same criteria (episode chaining) is harmless.
    static func match(refreshRate: Double, dynamicRange: DynamicRange) {
        guard spiAvailable else {
            #if DEBUG
            print("[FrameRateMatcher] AVDisplayCriteria SPI unavailable — skipping")
            #endif
            return
        }
        guard refreshRate > 1, refreshRate < 1000,
              let manager = displayManager else { return }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            #if DEBUG
            print("[FrameRateMatcher] Match Content disabled by user — skipping")
            #endif
            return
        }
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(refreshRate),
            videoDynamicRange: dynamicRange.rawValue
        )
        #if DEBUG
        print("[FrameRateMatcher] set output → \(refreshRate) Hz, dr=\(dynamicRange.rawValue)")
        #endif
    }

    /// Restores the system's default output mode. Call when the player closes;
    /// failing to do so leaves the Apple TV locked to the last content mode.
    static func reset() {
        guard spiAvailable, let manager = displayManager else { return }
        manager.preferredDisplayCriteria = nil
    }
}
