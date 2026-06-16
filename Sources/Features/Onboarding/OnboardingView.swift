import SwiftUI

struct OnboardingView: View {
    @StateObject private var vm = OnboardingViewModel()

    var body: some View {
        ZStack {
            Theme.background

            Group {
                switch vm.step {
                case .welcome: WelcomeStep(vm: vm)
                case .plexChoice: PlexChoiceStep(vm: vm)
                case .plexLink: PlexLinkStep(vm: vm)
                case .serverPick: ServerPickStep(vm: vm)
                case .manualConfig: ManualConfigStep(vm: vm)
                case .tmdb: TMDBStep(vm: vm)
                case .done: DoneStep(vm: vm)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .animation(.smooth(duration: 0.45), value: vm.step)
        .overlay(alignment: .bottom) { OnboardingSyncFooter() }
        .overlay { ToastOverlay() }
    }
}

/// During onboarding, shows the iCloud sync status and lets you pull the setup
/// already configured on another device. Only meaningful on the iCloud build.
private struct OnboardingSyncFooter: View {
    @ObservedObject private var sync = SyncCoordinator.shared
    @State private var busy = false

    var body: some View {
        HStack(spacing: 16) {
            Label("iCloud · \(sync.statusText)", systemImage: "icloud")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
            Button(busy ? "…" : tr(L.syncFindConfig)) {
                busy = true
                Task {
                    await SyncCoordinator.shared.syncNow()
                    busy = false
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(busy)
        }
        .padding(.bottom, 28)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("LumoraTV")
                .font(.system(size: 110, weight: .black, design: .rounded))
                .foregroundStyle(Theme.logoGradient)
            Text(tr(L.appTagline))
                .font(.title2)
                .foregroundStyle(.white.opacity(0.85))
            Text(tr(L.appSubtitle))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button(tr(L.start)) { vm.beginOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
            Spacer().frame(height: 60)
        }
    }
}

// MARK: - Step 2: How to connect

private struct PlexChoiceStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 50) {
            StepHeader(
                title: tr(L.connectTitle),
                subtitle: tr(L.connectSubtitle)
            )

            Text(tr(L.serverOptionalHint))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 900)

            HStack(spacing: 40) {
                Button { vm.beginPlexLink() } label: {
                    OptionCardLabel(
                        icon: "link.badge.plus",
                        title: tr(L.linkCardTitle),
                        description: tr(L.linkCardDesc),
                        badge: tr(L.recommended)
                    )
                }
                .buttonStyle(PremiumCardStyle())

                Button { vm.step = .manualConfig } label: {
                    OptionCardLabel(
                        icon: "gearshape.2",
                        title: tr(L.manualCardTitle),
                        description: tr(L.manualCardDesc),
                        badge: nil
                    )
                }
                .buttonStyle(PremiumCardStyle())
            }

            HStack(spacing: 30) {
                Button(tr(L.skipServerStep)) { vm.skipServer() }
                    .buttonStyle(PrimaryButtonStyle())
                Button(tr(L.back)) { vm.step = .tmdb }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private struct OptionCardLabel: View {
    let icon: String
    let title: String
    let description: String
    let badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.25), in: Capsule())
                        .foregroundStyle(Theme.accentSoft)
                }
            }
            Text(title)
                .font(.title3.weight(.bold))
            Text(description)
                .font(.callout)
                .opacity(0.7)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(32)
        .frame(width: 480, height: 290, alignment: .leading)
    }
}

// MARK: - Step 3: plex.tv/link code

private struct PlexLinkStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 44) {
            StepHeader(
                title: tr(L.linkTitle),
                subtitle: tr(L.linkSubtitle)
            )

            HStack(spacing: 90) {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 14) {
                        Image(systemName: "1.circle.fill").foregroundStyle(Theme.accent)
                        Text("\(tr(L.linkStep1)) \(Text("plex.tv/link").bold().foregroundStyle(.white))")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.title3)

                    HStack(spacing: 14) {
                        Image(systemName: "2.circle.fill").foregroundStyle(Theme.accent)
                        Text(tr(L.linkStep2)).foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.title3)

                    codeView
                }

                if let code = vm.pinCode {
                    VStack(spacing: 18) {
                        QRCodeView(content: "https://plex.tv/link?pin=\(code.uppercased())")
                            .frame(width: 260, height: 260)
                            .padding(20)
                            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        Label(tr(L.scanWithIphone), systemImage: "iphone.gen3")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(tr(L.codeAutofills))
                            .font(.caption)
                            .foregroundStyle(Theme.accentSoft)
                    }
                }
            }

            switch vm.linkState {
            case .working:
                HStack(spacing: 14) {
                    ProgressView()
                    Text(tr(L.waitingLink))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.callout)
            case .failed(let message):
                VStack(spacing: 20) {
                    Text(tr(message))
                        .font(.callout)
                        .foregroundStyle(.red.opacity(0.9))
                    Button(tr(L.newCode)) { vm.beginPlexLink() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            case .idle:
                EmptyView()
            }

            Button(tr(L.cancel)) { vm.cancelPlexLink() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var codeView: some View {
        if let code = vm.pinCode {
            HStack(spacing: 18) {
                ForEach(Array(code.uppercased().enumerated()), id: \.offset) { _, char in
                    Text(String(char))
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .frame(width: 90, height: 110)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Theme.accent.opacity(0.4), lineWidth: 2)
                        )
                        .foregroundStyle(.white)
                }
            }
        } else {
            ProgressView()
                .frame(height: 110)
        }
    }
}

// MARK: - Step 4: Pick server

private struct ServerPickStep: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 44) {
            StepHeader(
                title: tr(L.pickServerTitle),
                subtitle: tr(L.pickServerSubtitle)
            )

            switch vm.discoveryState {
            case .working:
                VStack(spacing: 18) {
                    ProgressView()
                    Text(tr(L.searchingServers))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(height: 300)
            case .failed(let message):
                VStack(spacing: 24) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 50))
                        .foregroundStyle(.orange)
                    Text(tr(message))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                    Button(tr(L.retry)) { vm.retryDiscovery() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .frame(height: 300)
            case .idle:
                HStack(spacing: 40) {
                    ForEach(vm.servers) { server in
                        Button { vm.select(server: server) } label: {
                            ServerCardLabel(server: server)
                        }
                        .buttonStyle(PremiumCardStyle())
                    }
                }
                .padding(.vertical, 30)
            }

            Button(tr(L.back)) { vm.step = .plexChoice }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

private struct ServerCardLabel: View {
    let server: ResolvedServer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(server.isLocal ? tr(L.localNetwork) : tr(L.remote))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        (server.isLocal ? Color.green : Color.orange).opacity(0.25),
                        in: Capsule()
                    )
                    .foregroundStyle(server.isLocal ? .green : .orange)
            }
            Text(server.name)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            Label(server.displayAddress, systemImage: "network")
                .font(.caption)
                .opacity(0.6)
                .lineLimit(1)
            if server.isLocal {
                Label(tr(L.directConnection), systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accentSoft)
            }
            Spacer()
        }
        .padding(32)
        .frame(width: 460, height: 250, alignment: .leading)
    }
}

// MARK: - Step 4b: Manual configuration

private struct ManualConfigStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var host = ""
    @State private var port = ""
    @State private var token = ""

    var body: some View {
        VStack(spacing: 36) {
            StepHeader(
                title: tr(L.manualTitle),
                subtitle: tr(L.manualTip)
            )

            VStack(spacing: 24) {
                TextField(tr(L.hostPlaceholder), text: $host)
                TextField(tr(L.portPlaceholder), text: $port)
                TextField(tr(L.tokenPlaceholder), text: $token)
            }
            .frame(maxWidth: 900)

            if case .failed(let message) = vm.manualState {
                Text(tr(message))
                    .font(.callout)
                    .foregroundStyle(.red.opacity(0.9))
            }

            HStack(spacing: 30) {
                Button {
                    vm.connectManually(host: host, port: port, token: token)
                } label: {
                    if vm.manualState == .working {
                        HStack(spacing: 12) { ProgressView(); Text(tr(L.connecting)) }
                    } else {
                        Text(tr(L.connect))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.manualState == .working)

                Button(tr(L.back)) { vm.step = .plexChoice }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

// MARK: - Step 5: TMDB

private struct TMDBStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var key = ""

    var body: some View {
        VStack(spacing: 36) {
            StepHeader(
                title: tr(L.tmdbTitle),
                subtitle: tr(L.tmdbSubtitle)
            )

            VStack(alignment: .leading, spacing: 16) {
                Label(tr(L.tmdbStep1), systemImage: "1.circle.fill")
                Label(tr(L.tmdbStep2), systemImage: "2.circle.fill")
                Label(tr(L.tmdbStep3), systemImage: "3.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))

            TextField(tr(L.tmdbPlaceholder), text: $key)
                .frame(maxWidth: 900)

            if case .failed(let message) = vm.tmdbState {
                Text(tr(message))
                    .font(.callout)
                    .foregroundStyle(.red.opacity(0.9))
            }

            HStack(spacing: 30) {
                Button {
                    vm.validateTMDB(key: key)
                } label: {
                    if vm.tmdbState == .working {
                        HStack(spacing: 12) { ProgressView(); Text(tr(L.validating)) }
                    } else {
                        Text(tr(L.validate))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.tmdbState == .working)

                Button(tr(L.back)) { vm.step = .welcome }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

// MARK: - Step 6: Done

private struct DoneStep: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 36) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 90))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.4), radius: 30)

            Text(tr(L.doneTitle))
                .font(.system(size: 56, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(settings.hasTMDB ? tr(L.tmdbActive) : tr(L.tmdbPending))
                } icon: {
                    Image(systemName: settings.hasTMDB ? "checkmark.circle.fill" : "minus.circle.fill")
                        .foregroundStyle(settings.hasTMDB ? .green : .orange)
                }
                if let server = settings.servers.last {
                    Label {
                        Text("\(tr(L.connectedTo)) \(Text(server.name).bold())")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label {
                        Text(tr(L.doneNoServer))
                    } icon: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .font(.title3)
            .foregroundStyle(.white.opacity(0.85))

            Spacer()
            Button(tr(L.exploreLibrary)) { vm.finish() }
                .buttonStyle(PrimaryButtonStyle())
            Spacer().frame(height: 60)
        }
    }
}

// MARK: - Shared

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.top, 60)
    }
}
