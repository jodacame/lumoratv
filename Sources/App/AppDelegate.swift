import UIKit
#if LUMORA_ICLOUD
import CloudKit
#endif

/// Recibe los push silenciosos de CloudKit para la sync en vivo. En el build gratis
/// no registra nada (todo el cuerpo va tras `#if LUMORA_ICLOUD`), así que la app
/// sigue 100% local. En tvOS el push solo llega con la app activa → es una pista;
/// el pull por change-token en foreground es la fuente de verdad (ver SyncCoordinator).
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if LUMORA_ICLOUD
        // Necesario para que `didReceiveRemoteNotification` se invoque.
        application.registerForRemoteNotifications()
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        #if LUMORA_ICLOUD
        let note = CKNotification(fromRemoteNotificationDictionary: userInfo)
        guard note?.notificationType == .database else { completionHandler(.noData); return }
        Task {
            await SyncCoordinator.shared.handleRemotePush()
            completionHandler(.newData)
        }
        #else
        completionHandler(.noData)
        #endif
    }
}
