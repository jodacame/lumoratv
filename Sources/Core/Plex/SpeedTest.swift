import Foundation
import GRDB

/// Measures the real bandwidth between the Apple TV and a Plex server.
/// Continuous download of a media file, discarding the TCP ramp-up
/// (warm-up) and measuring sustained throughput — the real transfer speed.
enum SpeedTest {

    enum SpeedError: LocalizedError {
        case noSample, failed
        var errorDescription: String? {
            switch self {
            case .noSample: tr(L.speedNoSample)
            case .failed: tr(L.speedFailed)
            }
        }
    }

    /// Returns sustained Mbps.
    static func run(serverID: String, baseURL: String, token: String) async throws -> Double {
        guard let partURL = try await samplePartURL(serverID: serverID, baseURL: baseURL, token: token) else {
            throw SpeedError.noSample
        }
        // Request a large range (up to 1 GB); the meter stops on its own once it has measured enough.
        var req = PlexClient.request(partURL, token: token)
        req.setValue("bytes=0-1073741823", forHTTPHeaderField: "Range")
        req.timeoutInterval = 20

        let meter = SpeedMeter()
        let mbps = await meter.measure(request: req)
        guard mbps > 0 else { throw SpeedError.failed }
        return mbps
    }

    private static func samplePartURL(serverID: String, baseURL: String, token: String) async throws -> URL? {
        let sample = try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem
                .filter(Column("serverID") == serverID && Column("type") == "movie")
                .fetchOne(db)
        }
        guard let ratingKey = sample?.ratingKey else { return nil }

        struct Container: Decodable {
            struct MC: Decodable {
                struct Meta: Decodable {
                    struct MediaInfo: Decodable {
                        struct Part: Decodable { let key: String }
                        let Part: [Part]?
                    }
                    let Media: [MediaInfo]?
                }
                let Metadata: [Meta]?
            }
            let MediaContainer: MC
        }
        guard let url = URL(string: baseURL + "/library/metadata/\(ratingKey)") else { return nil }
        let (data, resp) = try await URLSession.shared.data(for: PlexClient.request(url, token: token))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let key = try? JSONDecoder().decode(Container.self, from: data)
                  .MediaContainer.Metadata?.first?.Media?.first?.Part?.first?.key else { return nil }

        var comps = URLComponents(string: baseURL + key)
        comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return comps?.url
    }
}

/// Chunk-based meter: discards the first 8 MB (slow-start) and measures the
/// sustained transfer for ~6 s or up to 400 MB.
private final class SpeedMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Double, Never>?
    private var totalBytes = 0
    private var measuredBytes = 0
    private var measureStart: Date?
    private var firstByteAt: Date?
    private var done = false
    private var task: URLSessionDataTask?

    private let warmupBytes = 8_000_000
    private let maxMeasureBytes = 400_000_000
    private let maxDuration: TimeInterval = 6

    func measure(request: URLRequest) async -> Double {
        await withCheckedContinuation { cont in
            self.continuation = cont
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            let t = session.dataTask(with: request)
            self.task = t
            t.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !done else { return }
        let now = Date()
        if firstByteAt == nil { firstByteAt = now }
        totalBytes += data.count

        if measureStart == nil {
            // Still in warm-up: start measuring once past the threshold.
            if totalBytes >= warmupBytes {
                measureStart = now
                measuredBytes = 0
            }
            return
        }
        measuredBytes += data.count
        let elapsed = now.timeIntervalSince(measureStart!)
        if elapsed >= maxDuration || measuredBytes >= maxMeasureBytes {
            finish(measured: measuredBytes, seconds: elapsed)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !done else { return }
        // Finished (or failed) before filling the window: measure what was achieved.
        if let start = measureStart {
            finish(measured: measuredBytes, seconds: Date().timeIntervalSince(start))
        } else if let first = firstByteAt, totalBytes > 0 {
            // Small file: use everything that was transferred.
            finish(measured: totalBytes, seconds: Date().timeIntervalSince(first))
        } else {
            finish(measured: 0, seconds: 1)
        }
    }

    private func finish(measured: Int, seconds: TimeInterval) {
        guard !done else { return }
        done = true
        task?.cancel()
        let elapsed = max(seconds, 0.001)
        let mbps = Double(measured) * 8 / elapsed / 1_000_000
        continuation?.resume(returning: mbps)
        continuation = nil
    }
}
