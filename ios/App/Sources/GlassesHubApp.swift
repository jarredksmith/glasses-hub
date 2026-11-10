import SwiftUI

@main
struct GlassesHubApp: App {
    @StateObject private var model = HubModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.link)
                .environmentObject(model.pc)
                .onChange(of: phase) { _, new in
                    if new == .active { model.scene(active: true) }
                    else if new == .background { model.scene(active: false) }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            DisplayView().tabItem { Label("Display", systemImage: "eyeglasses") }
            AppsView().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            PCView().tabItem { Label("PC", systemImage: "desktopcomputer") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
