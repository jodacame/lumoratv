import AVFoundation
import UIKit

/// Extracts video frames at a given timestamp, straight from the stream (no server).
/// Uses VideoToolbox via AVAssetImageGenerator — decodes only the requested frame.
/// Limitation: AVFoundation cannot read MKV; for those, the caller uses another fallback.
actor VideoThumbnailer {
    static let shared = VideoThumbnailer()

    private var cache: [String: UIImage] = [:]

    func frame(url: URL, atSeconds seconds: Double) async -> UIImage? {
        // Quantize to 5s to reuse across nearby chapters.
        let bucket = (Int(seconds) / 5) * 5
        let key = "\(url.absoluteString)#\(bucket)"
        if let cached = cache[key] { return cached }

        guard let img = await Self.extract(url: url, seconds: Double(bucket)) else { return nil }
        cache[key] = img
        return img
    }

    func clear() {
        cache.removeAll()
    }

    /// Extraction isolated from the actor: the generator does not cross isolation boundaries.
    private nonisolated static func extract(url: URL, seconds: Double) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 420, height: 236)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        return await withCheckedContinuation { continuation in
            gen.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
                if let cgImage {
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
