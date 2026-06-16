import SwiftUI

/// Lightweight, app-wide transient notifications (e.g. iCloud sync activity).
/// Mount `ToastOverlay()` once at the root; call `ToastCenter.shared.show(...)`
/// from anywhere on the main actor.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var icon: String
    }

    @Published private(set) var current: Toast?
    private var dismiss: Task<Void, Never>?

    private init() {}

    func show(_ text: String, icon: String = "icloud", seconds: Double = 3) {
        current = Toast(text: text, icon: icon)
        dismiss?.cancel()
        dismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// Floating pill anchored at the top. Non-interactive (doesn't steal focus).
struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            if let toast = center.current {
                HStack(spacing: 12) {
                    Image(systemName: toast.icon)
                        .foregroundStyle(Theme.accentSoft)
                    Text(toast.text)
                        .foregroundStyle(.white)
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 26)
                .padding(.vertical, 15)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .padding(.top, 50)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.3), value: center.current)
        .allowsHitTesting(false)
    }
}
