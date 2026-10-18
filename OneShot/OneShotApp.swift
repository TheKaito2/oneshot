import FoundationModels
import SwiftData
import SwiftUI
import TipKit

@main
struct OneShotApp: App {
    init() {
        SeedAppearance.apply()
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
            Tab("Settings", systemImage: "gearshape.fill", value: AppModel.Tab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.font, .seed(.body))
        .id(legibilityWeight == .bold)
        .task {
            // Load the on-device model now, so Home's first insight doesn't pay for it (Foundation Lab "BasicPrewarming").
            if SystemLanguageModel.default.availability == .available { LanguageModelSession().prewarm() }
            let gallery = app.gallery
            Task.detached(priority: .utility) {
                Splitter.warmUp()
                gallery.seedFromBundle()
            }
            await app.camera.start()
            if app.cameraIdle { app.camera.pause() }
        }
        .onChange(of: app.cameraIdle) { _, idle in
            idle ? app.camera.pause() : app.camera.resume()
        }
    }
}
