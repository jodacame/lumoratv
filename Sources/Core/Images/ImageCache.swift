import SwiftUI
import CryptoKit

actor ImageCache {
    static let shared = ImageCache()

    private let dir: URL
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func data(for url: URL) async -> Data? {
        let key = Self.key(for: url)
        let file = dir.appendingPathComponent(key)
        if let cached = try? Data(contentsOf: file) {
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task<Data?, Never> {
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            return data
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data {
            try? data.write(to: file)
        }
        return data
    }

    // MARK: Storage management

    /// Bytes used by the disk cache.
    func totalSizeBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Deletes the entire disk cache.
    func purgeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// LRU purge: removes the least recently used files until under the limit.
    func enforceLimit(maxBytes: Int64) {
        guard maxBytes > 0 else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        var files: [(url: URL, size: Int64, date: Date)] = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys)
        )) ?? []).compactMap { file in
            let values = try? file.resourceValues(forKeys: keys)
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
            return (file, size, date)
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }
        files.sort { $0.date < $1.date }
        for file in files {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// In-memory cache of already decoded images: smooth scrolling in large catalogs.
enum ImageMemoryCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 800
        return cache
    }()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    static func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }

    static func clear() {
        cache.removeAllObjects()
    }
}

struct CachedAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// false for images with transparency (logos): no background placeholder.
    var showsPlaceholder: Bool = true
    /// When the image is missing or fails to load, show this title centered on a
    /// solid dark background instead of leaving a transparent/empty gap.
    var fallbackTitle: String? = nil

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if url == nil || didFail {
                // No image available: solid fallback, never a transparent gap.
                if showsPlaceholder || fallbackTitle != nil {
                    LinearGradient(
                        colors: [Color(white: 0.13), Color(white: 0.06)],
                        startPoint: .top, endPoint: .bottom
                    )
                    if let fallbackTitle, !fallbackTitle.isEmpty {
                        Text(fallbackTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .padding(14)
                    }
                }
            } else if showsPlaceholder {
                // Loading shimmer.
                Rectangle().fill(.white.opacity(0.05))
            }
        }
        .task(id: url) {
            didFail = false
            guard let url else { image = nil; didFail = true; return }
            // 1) Memory (instant, no flicker).
            if let cached = ImageMemoryCache.image(for: url) {
                image = cached
                return
            }
            // 2) Disk / network.
            if let data = await ImageCache.shared.data(for: url),
               let decoded = UIImage(data: data) {
                ImageMemoryCache.store(decoded, for: url)
                withAnimation(.smooth(duration: 0.22)) {
                    image = decoded
                }
            } else {
                didFail = true
            }
        }
    }
}
