import SwiftUI

/// FluxTorrent dashboard — a native, client-like view of the server's torrents
/// (progress, ⬇/⬆ speed, peers/seeders, ratio, disk usage) plus server disk info.
/// Only reachable when `SettingsStore.fluxTorrentAvailable` is true.
@MainActor
final class FluxTorrentViewModel: ObservableObject {
    @Published var torrents: [FluxTorrentClient.Torrent] = []
    @Published var disk: FluxTorrentClient.DiskInfo?
    @Published var settings: FluxTorrentClient.ServerSettings?
    @Published var loaded = false

    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                let snap = await FluxTorrentClient.snapshot(includeSettings: first)
                guard let self else { return }
                // Active downloads first, then by download speed, then by name.
                self.torrents = snap.torrents.sorted {
                    if $0.stats.downKbps != $1.stats.downKbps { return $0.stats.downKbps > $1.stats.downKbps }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self.disk = snap.disk
                if let s = snap.settings { self.settings = s }
                self.loaded = true
                first = false
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    var totalDownKbps: Double { torrents.reduce(0) { $0 + $1.stats.downKbps } }
    var totalUpKbps: Double { torrents.reduce(0) { $0 + $1.stats.upKbps } }
    var downloadingCount: Int { torrents.filter { $0.stats.state.lowercased() == "downloading" }.count }
    var seedingCount: Int { torrents.filter { $0.stats.state.lowercased() == "seeding" }.count }
}

// MARK: - Formatting

enum TFmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }
    static func mib(_ mb: Double) -> String { bytes(Int64(max(0, mb) * 1_048_576)) }
    /// Short, decimal-free size for chips (e.g. "638 GB", "2 TB").
    static func sizeShort(_ b: Int64) -> String {
        let gb = Double(max(0, b)) / 1_000_000_000
        if gb >= 1000 { return "\(Int((gb / 1000).rounded())) TB" }
        return "\(Int(gb.rounded())) GB"
    }
    /// kilobits/s → human MB/s.
    static func speed(_ kbps: Double) -> String {
        let mbps = kbps / 8000
        if mbps < 0.05 { return "0 MB/s" }
        return String(format: "%.1f MB/s", mbps)
    }
}

// MARK: - View

struct FluxTorrentView: View {
    @StateObject private var vm = FluxTorrentViewModel()
    @State private var expanded: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    if !vm.loaded {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                    } else if vm.torrents.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.torrents) { t in
                            TorrentRow(torrent: t, isExpanded: expanded == t.hash) {
                                withAnimation(.smooth(duration: 0.2)) {
                                    expanded = (expanded == t.hash) ? nil : t.hash
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 150)
                .padding(.bottom, 80)
            }
        }
        .task { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: Header (title + server/disk card)

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("FluxTorrent")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(Theme.logoGradient)

            // Stat chips spread evenly across the full width.
            HStack(spacing: 16) {
                statPill(icon: "tray.full.fill", tint: .white.opacity(0.7),
                         title: tr(L.fxTorrents), value: "\(vm.torrents.count)")
                statPill(icon: "square.and.arrow.down.fill", tint: Theme.accent,
                         title: tr(L.fxDownloading), value: "\(vm.downloadingCount)")
                statPill(icon: "arrow.down.circle.fill", tint: Theme.accent,
                         title: tr(L.fxDownRate), value: TFmt.speed(vm.totalDownKbps))
                statPill(icon: "arrow.up.circle.fill", tint: .green,
                         title: tr(L.fxUpRate), value: TFmt.speed(vm.totalUpKbps))
                if let disk = vm.disk {
                    statPill(icon: "internaldrive.fill", tint: diskTint(disk),
                             title: "\(tr(L.fxDisk)) · \(TFmt.sizeShort(disk.totalBytes))",
                             value: TFmt.sizeShort(disk.freeBytes))
                }
            }
        }
    }

    private func diskTint(_ disk: FluxTorrentClient.DiskInfo) -> Color {
        let frac = Double(disk.freeBytes) / max(Double(disk.totalBytes), 1)
        return frac < 0.1 ? .red : .white.opacity(0.7)
    }

    private func statPill(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray").font(.system(size: 60)).foregroundStyle(.white.opacity(0.3))
            Text(tr(L.fxNoTorrents)).font(.title3).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - Torrent row

private struct TorrentRow: View {
    let torrent: FluxTorrentClient.Torrent
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: isExpanded ? 14 : 8) {
                // Compact header line (single row — good for very long lists).
                HStack(spacing: 12) {
                    Circle().fill(stateTint(torrent.stats.state)).frame(width: 9, height: 9)
                    Text(torrent.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if torrent.private == true {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    if torrent.stats.downKbps > 0 {
                        Label(TFmt.speed(torrent.stats.downKbps), systemImage: "arrow.down")
                            .font(.caption).foregroundStyle(Theme.accent)
                    }
                    Text(String(format: "%.0f%%", torrent.stats.progress * 100))
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }

                ProgressBar(value: torrent.stats.progress, height: isExpanded ? 8 : 4)

                if isExpanded {
                    HStack {
                        StateBadge(state: torrent.stats.state)
                        Spacer()
                        Text("\(TFmt.mib(torrent.stats.cacheFillMB)) / \(TFmt.bytes(torrent.sizeBytes))")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    HStack(spacing: 22) {
                        metric("arrow.down", Theme.accent, TFmt.speed(torrent.stats.downKbps))
                        metric("arrow.up", .green, TFmt.speed(torrent.stats.upKbps))
                        metric("person.2.fill", .white.opacity(0.7), "\(torrent.stats.seeders)/\(torrent.stats.peers)")
                        metric("arrow.triangle.2.circlepath", .white.opacity(0.7), String(format: "%.2f", torrent.stats.ratio))
                    }
                    .font(.callout)
                    expandedDetail
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, isExpanded ? 20 : 12)
        }
        .buttonStyle(TorrentRowStyle())
    }

    private func metric(_ icon: String, _ tint: Color, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        Divider().overlay(.white.opacity(0.15))
        // Seed / dates.
        HStack(spacing: 22) {
            if let added = torrent.addedAt {
                detail(tr(L.fxAdded), Date(timeIntervalSince1970: TimeInterval(added)).formatted(date: .abbreviated, time: .shortened))
            }
            if let elapsed = torrent.seedElapsedMin, let target = torrent.seedTargetMinutes, torrent.keepSeed == true {
                detail(tr(L.fxSeedTime), "\(elapsed)/\(target) min")
            }
            if let r = torrent.seedTargetRatio, r > 0 {
                detail(tr(L.fxSeedRatio), String(format: "%.2f/%.0f", torrent.stats.ratio, r))
            }
            detail(tr(L.fxUploaded), TFmt.bytes(torrent.stats.uploadedBytes))
        }
        .font(.caption)

        // Peers.
        if let peers = torrent.peers, !peers.isEmpty {
            Text(tr(L.fxPeers)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(peers.prefix(8), id: \.addr) { p in
                    HStack(spacing: 10) {
                        Image(systemName: p.seeder == true ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(p.seeder == true ? .green : Theme.accent)
                        Text(p.addr).foregroundStyle(.white.opacity(0.7))
                        if let c = p.client { Text(c).foregroundStyle(.white.opacity(0.4)) }
                        Spacer()
                        if let d = p.downKbps { Text(TFmt.speed(d)).foregroundStyle(.white.opacity(0.6)) }
                    }
                    .font(.caption)
                }
            }
        }

        // Trackers.
        if let trackers = torrent.trackers, !trackers.isEmpty {
            Text(tr(L.fxTrackers)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            ForEach(trackers, id: \.self) { t in
                Text(t).font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).foregroundStyle(.white.opacity(0.85))
            Text(title).foregroundStyle(.white.opacity(0.4))
        }
    }
}

private func stateTint(_ state: String) -> Color {
    switch state.lowercased() {
    case "downloading": return Theme.accent
    case "seeding": return .green
    case "searching", "connecting": return .orange
    default: return .white.opacity(0.4)
    }
}

private struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(Theme.accent)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

private struct StateBadge: View {
    let state: String
    var body: some View {
        Text(state.capitalized)
            .font(.caption2.weight(.bold))
            .foregroundStyle(stateTint(state))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(stateTint(state).opacity(0.18)))
    }
}

private struct TorrentRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledRow(configuration: configuration)
    }
    private struct StyledRow: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(focused ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0), lineWidth: 2)
                )
                .scaleEffect(focused ? 1.01 : 1.0)
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}
