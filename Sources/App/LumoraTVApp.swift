import SwiftUI

@main
struct LumoraTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var l10n = L10nStore.shared
    @StateObject private var profiles = ProfileStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !settings.isConfigured {
                    OnboardingView()
                } else if profiles.needsSelection {
                    ProfileGateView()
                } else {
                    MainView()
                }
            }
            .preferredColorScheme(.dark)
            .animation(.smooth(duration: 0.5), value: settings.isConfigured)
            .id(l10n.language) // rebuilds the UI when the language changes
            // URL scheme (Top Shelf / links): lumoratv://item/<mergeKey>
            .onOpenURL { url in
                DeepLinkRouter.shared.handle(url: url)
            }
            .animation(.smooth(duration: 0.4), value: profiles.needsSelection)
            // Aplica el parental del perfil activo + arranca sync (no-op sin iCloud).
            .onAppear {
                profiles.applyActiveParental()
                SyncCoordinator.shared.bootstrap()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    SyncCoordinator.shared.applicationDidBecomeActive()
                    // Al reabrir la app (tras segundo plano), volver a preguntar
                    // "¿quién está viendo?". Un inactivo breve (Control Center) NO cuenta.
                    if wasBackgrounded { profiles.requestSelection(); wasBackgrounded = false }
                case .background:
                    wasBackgrounded = true
                    SyncCoordinator.shared.applicationWillResignActive()
                case .inactive:
                    SyncCoordinator.shared.applicationWillResignActive()
                @unknown default:
                    break
                }
            }
        }
    }
}
