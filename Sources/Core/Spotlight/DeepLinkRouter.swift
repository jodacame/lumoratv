import SwiftUI
import GRDB

/// Routes external opens (Top Shelf, URL scheme) to the content's detail view.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var pendingItem: MediaItem?

    private init() {}

    /// Open via URL scheme: lumoratv://item/<mergeKey>
    func handle(url: URL) {
        guard url.scheme == "lumoratv", url.host == "item" else { return }
        let key = url.pathComponents.dropFirst().joined(separator: "/")
        guard !key.isEmpty else { return }
        Task {
            let raw = (try? await AppDatabase.shared.dbQueue.read { db in
                try MediaItem.fetchAll(db)
            }) ?? []
            pendingItem = raw.first { $0.mergeKey == key }
        }
    }
}
