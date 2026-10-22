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
        Diagnostics.shared.start()
        // An install already in use (its catalog came over from the old files) never sees onboarding.
        if UserDefaults.standard.object(forKey: OnboardingKey.done) == nil, !Catalog.isEmpty(Store.context) {
            UserDefaults.standard.set(true, forKey: OnboardingKey.done)
        }
        do {
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            Log.error("tips: \(error)")
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
    /// Read once: a `-onboarded NO` launch argument (UI tests) outranks the write at the end, so the cover can't follow it.
    @State private var onboarding = !UserDefaults.standard.bool(forKey: OnboardingKey.done)
    @State private var account = Account.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Custom fonts don't follow Bold Text by themselves: rebuild with the heavier faces when it changes.
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house.fill", value: AppModel.Tab.home) {
                phoneBar(HomeView(app: app))
            }
            Tab("Products", systemImage: "square.grid.2x2.fill", value: AppModel.Tab.products) {
                phoneBar(ProductsView(app: app))
            }
            Tab("Checkout", systemImage: "viewfinder", value: AppModel.Tab.checkout) {
                phoneBar(CheckoutView(app: app))
            }
            Tab("Reports", systemImage: "chart.bar.xaxis", value: AppModel.Tab.reports) {
                phoneBar(ReportsView(app: app))
            }
            // iPhone only: on iPad a fifth title overflowed the portrait top bar (19 Oct); there Home's gear opens it.
            if sizeClass == .compact {
                Tab("Settings", systemImage: "gearshape.fill", value: AppModel.Tab.settings) {
                    phoneBar(SettingsView(app: app, inTab: true))
                }
            }
        }
        // iPad: Settings is a sheet from Home's gear, not a fifth tab: five titles overflowed the portrait tab bar, and
        // as a sidebar-only tab it still joined the bar when selected and pushed Home behind a chevron (19 Oct).
        .sheet(isPresented: $app.showingSettings) { SettingsView(app: app) }
        .fullScreenCover(isPresented: $onboarding) {
            OnboardingView(app: app) { onboarding = false }
                .environment(\.font, .seed(.body))
        }
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
        // Signed in: sync now, then every 5 minutes (sales also nudge it). Signed out, the loop isn't running.
        .task(id: account.email) {
            guard account.isSignedIn else { return }
            while !Task.isCancelled {
                await SyncEngine.shared.sync(app)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        // Demo bills the table photos' snacks, so it needs them in the catalog (a fresh install has none).
        .task(id: app.demo) { if app.demo { app.addSampleProducts() } }
        .onChange(of: app.cameraIdle) { _, idle in
            idle ? app.camera.pause() : app.camera.resume()
        }
    }
}

extension RootView {
    /// iPhone: the system tab bar makes way for OneShot's own, with Checkout as the raised centre button.
    @ViewBuilder
    func phoneBar(_ page: some View) -> some View {
        if sizeClass == .compact {
            page
                .toolbarVisibility(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { PhoneTabBar(tab: $app.tab) }
        } else {
            page
        }
    }
}

/// Home · Products · (Checkout) · Reports · Settings, with Checkout a raised coral circle in the middle: the main
/// action where the thumb rests, as Instagram, TikTok and Venmo place theirs (Krist, 22 Oct).
struct PhoneTabBar: View {
    @Binding var tab: AppModel.Tab

    var body: some View {
        HStack(spacing: 0) {
            item(.home, "Home", "house.fill")
            item(.products, "Products", "square.grid.2x2.fill")
            checkout
            item(.reports, "Reports", "chart.bar.xaxis")
            item(.settings, "Settings", "gearshape.fill")
        }
        .padding(.horizontal, 6)
        .frame(height: 62)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: tab)
    }

    private func item(_ value: AppModel.Tab, _ title: LocalizedStringKey, _ icon: String) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                Text(title).font(.seed(size: 10, .bold, relativeTo: .caption2)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(tab == value ? Brand.accent : Brand.ink)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private var checkout: some View {
        Button { tab = .checkout } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Brand.buttonFill, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(tab == .checkout ? 0.9 : 0.35), lineWidth: 3))
                .shadow(color: Brand.buttonFill.opacity(0.45), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .offset(y: -16)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text("Checkout"))
        .accessibilityAddTraits(tab == .checkout ? .isSelected : [])
    }
}
