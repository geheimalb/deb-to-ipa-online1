import SwiftUI
#if CARPLAY
import CarPlay
#endif

@main
struct MofaNaviApp: App {
    #if CARPLAY
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

#if CARPLAY
/// Leitet die CarPlay-Szene an den CarPlaySceneDelegate weiter.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return connectingSceneSession.configuration
    }
}
#endif
