import SwiftUI
import UIKit

/// Carga un PNG de avatar empaquetado (Resources/Avatars/<name>.png).
enum AvatarImage {
    static func load(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - Paleta de avatares

enum ProfilePalette {
    static let gradients: [[Color]] = [
        [Color(red: 1.00, green: 0.42, blue: 0.21), Color(red: 0.96, green: 0.16, blue: 0.34)],
        [Color(red: 0.30, green: 0.52, blue: 1.00), Color(red: 0.46, green: 0.28, blue: 0.94)],
        [Color(red: 0.18, green: 0.80, blue: 0.62), Color(red: 0.13, green: 0.55, blue: 0.55)],
        [Color(red: 0.98, green: 0.62, blue: 0.20), Color(red: 0.95, green: 0.36, blue: 0.13)],
        [Color(red: 0.92, green: 0.34, blue: 0.66), Color(red: 0.60, green: 0.22, blue: 0.78)],
        [Color(red: 0.36, green: 0.74, blue: 0.40), Color(red: 0.16, green: 0.52, blue: 0.34)],
        [Color(red: 0.30, green: 0.72, blue: 0.92), Color(red: 0.20, green: 0.42, blue: 0.82)],
        [Color(red: 0.86, green: 0.46, blue: 0.30), Color(red: 0.52, green: 0.30, blue: 0.26)],
    ]
    static var count: Int { gradients.count }
    static func clampedIndex(_ i: Int) -> Int { ((i % count) + count) % count }
    static func gradient(_ i: Int) -> LinearGradient {
        LinearGradient(colors: gradients[clampedIndex(i)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func colors(_ i: Int) -> [Color] { gradients[clampedIndex(i)] }
}

/// Fondo de avatar moderno: un MeshGradient (tvOS 18+) que se mueve suavemente.
struct AnimatedMeshAvatar: View {
    let colorIndex: Int
    var body: some View {
        let pair = ProfilePalette.colors(colorIndex)
        let a = pair[0], b = pair[1]
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let dx = Float(sin(t * 0.55) * 0.16)
            let dy = Float(cos(t * 0.43) * 0.16)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    .init(0, 0), .init(0.5, 0), .init(1, 0),
                    .init(0, 0.5), .init(0.5 + dx, 0.5 + dy), .init(1, 0.5),
                    .init(0, 1), .init(0.5, 1), .init(1, 1),
                ],
                colors: [b, a, b, a, b, a, b, a, b]
            )
        }
    }
}

// MARK: - Avatar

struct ProfileAvatar: View {
    let profile: AppProfile
    var size: CGFloat = 170
    /// Degradado animado + flotación (selector); en grids grandes conviene `false`.
    var animated: Bool = true

    @State private var image: UIImage?
    @State private var breathe = false

    var body: some View {
        ZStack {
            if let image {
                // El PNG ya trae su propio fondo de color → a sangre completa.
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .scaleEffect(animated && breathe ? 1.05 : 1.0)
            } else {
                if animated { AnimatedMeshAvatar(colorIndex: profile.colorIndex) }
                else { ProfilePalette.gradient(profile.colorIndex) }
                Text(String(profile.name.first ?? "?").uppercased())
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottom) {
            if profile.isKid {
                Text("KIDS")
                    .font(.system(size: size * 0.11, weight: .heavy, design: .rounded))
                    .kerning(1)
                    .padding(.horizontal, size * 0.10)
                    .padding(.vertical, size * 0.04)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundStyle(.white)
                    .offset(y: size * 0.12)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
        .task(id: profile.avatar) { image = profile.avatar.flatMap(AvatarImage.load) }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Fila tipo "card" con foco limpio (fondo claro + leve escala).
struct ProfileCardRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: 620, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(focused ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
                )
                .scaleEffect(focused ? 1.015 : 1.0)
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

/// Tile con escala + glow al enfocar (estilo Apple TV).
struct ProfileTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .scaleEffect(focused ? 1.12 : 1.0)
                .shadow(color: focused ? Theme.accent.opacity(0.5) : .clear, radius: 30, y: 12)
                .brightness(focused ? 0.04 : 0)
                .animation(.smooth(duration: 0.25), value: focused)
        }
    }
}

// MARK: - Selector "¿Quién está viendo?"

struct ProfileGateView: View {
    @ObservedObject private var store = ProfileStore.shared
    @State private var editing: ProfileEditTarget?
    @State private var pin: PinChallenge?
    @State private var managing = false

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 700)
                .ignoresSafeArea()

            VStack(spacing: 70) {
                Text(managing ? tr(L.profileManage) : tr(L.profileWhoWatching))
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(alignment: .top, spacing: 50) {
                    ForEach(store.profiles) { p in
                        Button { tap(p) } label: { tile(avatar: ProfileAvatar(profile: p), label: p.name) }
                            .buttonStyle(ProfileTileStyle())
                    }
                    if managing || store.profiles.count < ProfilePalette.count {
                        Button { editing = .new } label: { addTile }
                            .buttonStyle(ProfileTileStyle())
                    }
                }

                HStack(spacing: 24) {
                    Button(managing ? tr(L.profileDone) : tr(L.profileManage)) {
                        if managing { managing = false } else { requireManage() }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    if managing {
                        Button(store.hasPIN ? "PIN ✓" : tr(L.profilePinCreate)) {
                            pin = PinChallenge(mode: .create) { _ in }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(40)
        }
        .fullScreenCover(item: $editing) { ProfileEditorView(target: $0) }
        .fullScreenCover(item: $pin) { PinView(challenge: $0) }
    }

    private func tile(avatar: ProfileAvatar, label: String) -> some View {
        VStack(spacing: 20) {
            avatar
            Text(label).font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
    }

    private var addTile: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                Circle().strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                Image(systemName: "plus").font(.system(size: 60, weight: .light)).foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 170, height: 170)
            Text(tr(L.profileAdd)).font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
    }

    private func tap(_ p: AppProfile) {
        if managing { editing = .existing(p); return }
        if p.isKid || !store.hasPIN { store.select(p.id); return }
        pin = PinChallenge(mode: .verify) { ok in if ok { store.select(p.id) } }
    }

    private func requireManage() {
        guard store.hasPIN else { managing = true; return }
        pin = PinChallenge(mode: .verify) { ok in if ok { managing = true } }
    }
}

// MARK: - Editor de perfil

enum ProfileEditTarget: Identifiable {
    case new
    case existing(AppProfile)
    var id: String { if case .existing(let p) = self { return p.id } else { return "new" } }
}

struct ProfileEditorView: View {
    let target: ProfileEditTarget
    @ObservedObject private var store = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isKid: Bool
    @State private var level: Int      // 0=G · 1=PG · 2=PG-13 (solo si es kids)
    @State private var colorIndex: Int
    @State private var avatar: String?
    @State private var confirmDelete = false

    private let editingID: String?

    init(target: ProfileEditTarget) {
        self.target = target
        switch target {
        case .new:
            _name = State(initialValue: "")
            _isKid = State(initialValue: false)
            _level = State(initialValue: 1)
            _colorIndex = State(initialValue: Int.random(in: 0..<ProfilePalette.count))
            _avatar = State(initialValue: AppProfile.avatars.randomElement())
            editingID = nil
        case .existing(let p):
            _name = State(initialValue: p.name)
            _isKid = State(initialValue: p.isKid)
            _level = State(initialValue: p.parentalLevel ?? 1)
            _colorIndex = State(initialValue: p.colorIndex)
            _avatar = State(initialValue: p.avatar)
            editingID = p.id
        }
    }

    private var preview: AppProfile {
        AppProfile(id: editingID ?? "preview", name: name.isEmpty ? "?" : name,
                   isKid: isKid, parentalLevel: isKid ? level : nil, colorIndex: colorIndex, avatar: avatar)
    }

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(spacing: 34) {
                    Text(editingID == nil ? tr(L.profileNew) : tr(L.profileEdit))
                        .font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(.white)

                    ProfileAvatar(profile: preview, size: 150)

                    TextField(tr(L.profileNamePlaceholder), text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 520)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                    // Color
                    VStack(spacing: 12) {
                        Text(tr(L.profileColor).uppercased()).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.45)).kerning(1.2)
                        HStack(spacing: 16) {
                            ForEach(0..<ProfilePalette.count, id: \.self) { i in
                                Button { colorIndex = i } label: {
                                    Circle().fill(ProfilePalette.gradient(i)).frame(width: 56, height: 56)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: colorIndex == i ? 4 : 0))
                                }
                                .buttonStyle(ProfileTileStyle())
                            }
                        }
                    }

                    // Avatar (PNG CC0)
                    VStack(spacing: 12) {
                        Text(tr(L.profileAvatar).uppercased()).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.45)).kerning(1.2)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(86), spacing: 16), count: 7), spacing: 16) {
                            Button { avatar = nil } label: {
                                ProfileAvatar(profile: AppProfile(name: name.isEmpty ? "?" : name, colorIndex: colorIndex, avatar: nil), size: 76, animated: false)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: avatar == nil ? 4 : 0))
                            }.buttonStyle(ProfileTileStyle())
                            ForEach(AppProfile.avatars, id: \.self) { a in
                                Button { avatar = a } label: {
                                    ProfileAvatar(profile: AppProfile(name: name, colorIndex: colorIndex, avatar: a), size: 76, animated: false)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: avatar == a ? 4 : 0))
                                }.buttonStyle(ProfileTileStyle())
                            }
                        }
                        .frame(maxWidth: 760)
                    }

                    // Kids (fila-botón con switch dibujado; foco limpio)
                    Button { isKid.toggle() } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr(L.profileKid))
                                Text(tr(L.profileKidHint)).font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            Capsule()
                                .fill(isKid ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.22)))
                                .frame(width: 64, height: 36)
                                .overlay(
                                    Circle().fill(.white).padding(4)
                                        .frame(width: 36, height: 36)
                                        .offset(x: isKid ? 14 : -14)
                                )
                                .animation(.smooth(duration: 0.2), value: isKid)
                        }
                    }
                    .buttonStyle(ProfileCardRowStyle())

                    if isKid {
                        VStack(spacing: 12) {
                            Text(tr(L.profileLevel).uppercased()).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.45)).kerning(1.2)
                            HStack(spacing: 14) {
                                ForEach(0..<3, id: \.self) { lvl in
                                    Button(Self.levelName(lvl)) { level = lvl }
                                        .buttonStyle(ChipButtonStyle(selected: level == lvl))
                                }
                            }
                        }
                    }

                    HStack(spacing: 20) {
                        Button(tr(L.profileSave)) { save() }.buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(tr(L.profileCancel)) { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 8)

                    if editingID != nil && store.profiles.count > 1 && editingID != store.selectedID {
                        Button(tr(L.profileDelete)) { confirmDelete = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(50)
            }
        }
        .alert(tr(L.profileDeleteConfirm), isPresented: $confirmDelete) {
            Button(tr(L.profileDelete), role: .destructive) {
                if let id = editingID { store.remove(id) }
                dismiss()
            }
            Button(tr(L.profileCancel), role: .cancel) {}
        } message: {
            Text(tr(L.profileDeleteMsg))
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let lvl = isKid ? level : nil
        if let id = editingID, let existing = store.profiles.first(where: { $0.id == id }) {
            var p = existing
            p.name = trimmed; p.isKid = isKid; p.parentalLevel = lvl; p.colorIndex = colorIndex; p.avatar = avatar
            store.update(p)
        } else {
            store.add(name: trimmed, isKid: isKid, parentalLevel: lvl, colorIndex: colorIndex, avatar: avatar)
        }
        dismiss()
    }

    static func levelName(_ lvl: Int) -> String {
        switch lvl { case 0: return "G"; case 1: return "PG"; default: return "PG-13" }
    }
}

// MARK: - PIN del hogar

struct PinChallenge: Identifiable {
    enum Mode { case verify, create }
    let id = UUID()
    let mode: Mode
    let onResult: (Bool) -> Void
}

struct PinView: View {
    let challenge: PinChallenge
    @ObservedObject private var store = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var error = false

    private let digits = ["1","2","3","4","5","6","7","8","9","","0","⌫"]

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 40) {
                Text(challenge.mode == .create ? tr(L.profilePinCreate) : tr(L.profilePinEnter))
                    .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                if challenge.mode == .create {
                    Text(tr(L.profilePinHint)).font(.callout).foregroundStyle(.white.opacity(0.5))
                }
                // Dots
                HStack(spacing: 22) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i < entry.count ? Theme.accent : Color.white.opacity(0.18))
                            .frame(width: 26, height: 26)
                    }
                }
                .modifier(Shake(animatableData: error ? 1 : 0))
                if error { Text(tr(L.profilePinWrong)).foregroundStyle(Theme.accent).font(.callout) }

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 22), count: 3), spacing: 22) {
                    ForEach(digits, id: \.self) { d in
                        if d.isEmpty { Color.clear.frame(width: 110, height: 90) }
                        else {
                            Button(d) { press(d) }
                                .buttonStyle(PinKeyStyle())
                        }
                    }
                }
                .frame(width: 410)

                Button(tr(L.profileCancel)) { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(50)
        }
    }

    private func press(_ d: String) {
        error = false
        if d == "⌫" { if !entry.isEmpty { entry.removeLast() }; return }
        guard entry.count < 4 else { return }
        entry.append(d)
        guard entry.count == 4 else { return }
        switch challenge.mode {
        case .create:
            store.setPIN(entry)
            challenge.onResult(true); dismiss()
        case .verify:
            if store.verifyPIN(entry) { challenge.onResult(true); dismiss() }
            else { withAnimation(.default) { error = true }; entry = "" }
        }
    }
}

private struct PinKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .frame(width: 110, height: 90)
                .background(focused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.10)), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
                .scaleEffect(focused ? 1.08 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

/// Sacudida al fallar el PIN.
private struct Shake: AnimatableModifier {
    var animatableData: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: sin(animatableData * .pi * 4) * 12)
    }
}
