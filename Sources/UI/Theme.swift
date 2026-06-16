import SwiftUI

enum Theme {
    static let bgTop = Color(red: 0.05, green: 0.05, blue: 0.12)
    static let bgBottom = Color.black
    // Strong orange leaning toward red.
    static let accent = Color(red: 1.00, green: 0.27, blue: 0.08)
    static let accentSoft = Color(red: 1.00, green: 0.48, blue: 0.32)
    static let violet = Color(red: 0.82, green: 0.10, blue: 0.12)

    static var focusBorder: LinearGradient {
        LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var background: some View {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    static var logoGradient: LinearGradient {
        LinearGradient(colors: [.white, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 56)
                .padding(.vertical, 18)
                .background(focused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
                .foregroundStyle(.white)
                .scaleEffect(focused ? 1.05 : 1.0)
                .shadow(color: focused ? Theme.accent.opacity(0.45) : .clear, radius: 24, y: 10)
                .animation(.smooth(duration: 0.2), value: focused)
        }
    }
}

struct PremiumCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: focused
                                        ? [.white.opacity(0.14), Theme.accent.opacity(0.12)]
                                        : [.white.opacity(0.06), .white.opacity(0.02)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(
                            focused ? AnyShapeStyle(Theme.focusBorder) : AnyShapeStyle(.white.opacity(0.10)),
                            lineWidth: focused ? 2.5 : 1
                        )
                )
                .compositingGroup()
                .shadow(
                    color: focused ? Theme.accent.opacity(0.35) : .black.opacity(0.45),
                    radius: focused ? 38 : 16,
                    y: focused ? 20 : 10
                )
                .scaleEffect(focused ? 1.07 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(.smooth(duration: 0.3), value: focused)
                .animation(.smooth(duration: 0.15), value: configuration.isPressed)
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .padding(.horizontal, 36)
                .padding(.vertical, 12)
                .background(focused ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.clear), in: Capsule())
                .foregroundStyle(focused ? .white : .white.opacity(0.55))
                .scaleEffect(focused ? 1.04 : 1.0)
                .animation(.smooth(duration: 0.2), value: focused)
        }
    }
}

/// Selectable chip (e.g. season picker). Highlights the active and the focused one.
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, selected: selected)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool

        private var fill: AnyShapeStyle {
            if focused { return AnyShapeStyle(Color.white) }
            if selected { return AnyShapeStyle(Theme.accent.opacity(0.85)) }
            return AnyShapeStyle(Color.white.opacity(0.14))
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, 26)
                .padding(.vertical, 11)
                .background(fill, in: Capsule())
                .foregroundStyle(focused ? .black : .white)
                .scaleEffect(focused ? 1.06 : 1.0)
                .animation(.smooth(duration: 0.2), value: focused)
        }
    }
}

