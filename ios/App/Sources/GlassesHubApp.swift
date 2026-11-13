import SwiftUI

/// Collects the address Apple gives this app for push notifications. The PC link passes it to the PC.
final class PushDelegate: NSObject, UIApplicationDelegate {
    static let tokenKey = "push.token"
    static let changed = Notification.Name("GlassesHubPushTokenChanged")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()        // gets the address; showing alerts is a separate permission
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard token != UserDefaults.standard.string(forKey: PushDelegate.tokenKey) else { return }
        UserDefaults.standard.set(token, forKey: PushDelegate.tokenKey)
        NotificationCenter.default.post(name: PushDelegate.changed, object: nil)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "push.error")
    }
}

@main
struct GlassesHubApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var model = HubModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.link)
                .environmentObject(model.pc)
                .modifier(TranslationHost())
                .onOpenURL { model.open(url: $0) }
                .onChange(of: phase) { _, new in
                    if new == .active { model.scene(active: true) }
                    else if new == .background { model.scene(active: false) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: HubModel
    /// The tab to open on. Normally the first; a "-startTab N" launch argument picks another (used
    /// when taking screenshots).
    @State private var tab = UserDefaults.standard.integer(forKey: "startTab")
    var body: some View {
        TabView(selection: $tab) {
            DisplayView().tabItem { Label("Display", systemImage: "eyeglasses") }.tag(0)
            AppsView().tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(1)
            PCView().tabItem { Label("PC", systemImage: "desktopcomputer") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .sheet(isPresented: Binding(get: { !model.setupSeen }, set: { if !$0 { model.setupSeen = true } })) { SetupView() }
    }
}
