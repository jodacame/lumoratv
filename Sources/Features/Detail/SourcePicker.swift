import SwiftUI

/// Single, agnostic source picker: lists server versions and torrent releases
/// (singles before packs, already sorted by the resolver). The view knows nothing
/// about services; it just renders the `Option` values it receives.
struct SourcePicker: View {
    let options: [PlaybackResolver.Option]
    let onSelect: (PlaybackResolver.Option?) -> Void

    @State private var provider: String?   // nil = all providers

    private var servers: [PlaybackResolver.Option] { options.filter(\.isServer) }
    private var torrents: [PlaybackResolver.Option] { options.filter { !$0.isServer } }

    /// Providers (indexers) present, for the filter.
    private var providers: [String] {
        var seen = Set<String>(), result: [String] = []
        for t in torrents { if let p = t.provider, !p.isEmpty, seen.insert(p).inserted { result.append(p) } }
        return result.sorted()
    }

    private var filteredTorrents: [PlaybackResolver.Option] {
        guard let provider else { return torrents }
        return torrents.filter { $0.provider == provider }
    }

    var body: some View {
        ZStack {
            // Modal with blurred background.
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark).ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr(L.chooseVersion))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    if !servers.isEmpty {
                        sectionLabel(tr(L.serversTitle))
                        ForEach(servers) { option in row(option) }
                    }

                    if !torrents.isEmpty {
                        sectionLabel("TORRENTS").padding(.top, servers.isEmpty ? 0 : 4)

                        // Filter by provider (only if there is more than one).
                        if providers.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    providerChip(label: tr(L.filterAllShort), value: nil)
                                    ForEach(providers, id: \.self) { p in providerChip(label: p, value: p) }
                                }
                                .padding(.vertical, 2)
                            }
                            .scrollClipDisabled()
                            .focusSection()
                        }

                        ForEach(filteredTorrents) { option in row(option) }
                    }

                    Button(tr(L.cancel)) { onSelect(nil) }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 6)
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onExitCommand { onSelect(nil) }
    }

    private func providerChip(label: String, value: String?) -> some View {
        Button { provider = value } label: {
            Text(label).font(.callout.weight(.semibold)).lineLimit(1)
        }
        .buttonStyle(ChipButtonStyle(selected: provider == value))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(1.2)
    }

    private func row(_ option: PlaybackResolver.Option) -> some View {
        Button { onSelect(option) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: option.isServer ? "server.rack" : "arrow.down.circle")
                        .foregroundStyle(Theme.accent)
                    Text(option.title)
                        .font(.callout.weight(.bold))
                    if option.isServer, !option.qualityLabel.isEmpty {
                        Text(option.qualityLabel)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    ForEach(option.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.accentSoft)
                    }
                    Spacer()
                    if let seeders = option.seeders {
                        Label("\(seeders)", systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(seeders > 10 ? .green : .orange)
                    }
                    if let sizeGB = option.sizeGB {
                        Text(String(format: "%.1f GB", sizeGB))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                HStack(spacing: 8) {
                    if let provider = option.provider, !provider.isEmpty {
                        Label(provider, systemImage: "globe")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accentSoft.opacity(0.9))
                    }
                    if let detail = option.detailTitle {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 820, alignment: .leading)
            .padding(18)
        }
        .buttonStyle(PremiumCardStyle())
    }
}
