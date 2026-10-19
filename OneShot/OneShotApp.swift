import AVFoundation
import FoundationModels
import SwiftData
import SwiftUI
import TipKit

@main
struct OneShotApp: App {
    init() {
        SeedAppearance.apply()
        AudioMode.mixed()   // the first ring-up chime was silent in Silent Mode until a payment set the session
        do {
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            print("tips: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(Store.container)
        }
    }
}

struct RootView: View {
    @State private var app = AppModel()
    /// Custom fonts don't follow Bold Text by themselves: rebuild with the heavier faces when it changes.
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house.fill", value: AppModel.Tab.home) {
                HomeView(app: app)
            }
            Tab("Checkout", systemImage: "bolt.fill", value: AppModel.Tab.checkout) {
                CheckoutView(app: app)
            }
            Tab("Products", systemImage: "square.grid.2x2.fill", value: AppModel.Tab.products) {
                ProductsView(app: app)
            }
            Tab("Reports", systemImage: "chart.bar.xaxis", value: AppModel.Tab.reports) {
                ReportsView(app: app)
            }
        }
        // Settings is a sheet from Home's gear, not a fifth tab: five titles overflowed the portrait tab bar, and as a
        // sidebar-only tab it still joined the bar when selected and pushed Home behind a chevron (19 Oct).
        .sheet(isPresented: $app.showingSettings) { SettingsView(app: app) }
        .tabViewStyle(.sidebarAdaptable)
        // Top tab bar by default in every orientation; the sidebar is one tap away (its button in the bar).
        .defaultAdaptableTabBarPlacement(.tabBar)
        .environment(\.font, .seed(.body))
        .id(legibilityWeight == .bold)
        .task {
            // Load the on-device model now, so Home's first insight doesn't pay for it (Foundation Lab "BasicPrewarming").
            if SystemLanguageModel.default.availability == .available { LanguageModelSession().prewarm() }
            let gallery = app.gallery
            // On the camera's queue, after the detector: the first launch after an install compiles every model for
            // this iPad, and compiling them on two threads at once froze the app (fine again after a relaunch).
            await app.camera.start()   // queues the detector load first
            app.camera.afterModelLoad {
                Splitter.warmUp()
                gallery.seedFromBundle()
            }
            if app.cameraIdle { app.camera.pause() }
        }
        .onChange(of: app.cameraIdle) { _, idle in
            idle ? app.camera.pause() : app.camera.resume()
        }
    }
}
