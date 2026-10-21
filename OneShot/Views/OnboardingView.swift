import AVFoundation
import SwiftUI

enum OnboardingKey {
    /// Set once the first-launch flow is done (or skipped by an install that was already in use).
    static let done = "onboarded"
}

/// First launch: what OneShot does, the camera, the shop's name and PromptPay ID, an optional refund PIN, where the
/// products come from, and an optional account. Every step but the welcome can be skipped and changed in Settings.
struct OnboardingView: View {
    @Bindable var app: AppModel
    /// Called when the flow ends.
    let onDone: () -> Void

    private enum Step: Int, CaseIterable { case welcome, camera, shop, promptPay, pin, products, account }

    @State private var step = Step.welcome
    @AppStorage(SettingsKey.shopName) private var shopName = ""
    @AppStorage(SettingsKey.promptPayID) private var promptPayID = ""
    @State private var draftID = ""
    @State private var pin = ""
    @State private var problem: String?
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var signingIn = false
    @FocusState private var typing: Bool

    /// The account step only exists in a build that has a backend to sign in to.
    private var steps: [Step] { Step.allCases.filter { $0 != .account || Cloud.isConfigured } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content.frame(maxWidth: 560, alignment: .leading)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.center, for: .alignment)
            footer
        }
        .background(GridBackground())
        .animation(.easeOut(duration: 0.25), value: step)
        .sheet(isPresented: $signingIn) { AccountView(app: app) }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            LogoTile(size: 72)
            Text("ONE-TAP CHECKOUT").eyebrow()
            Text("Ring up the whole counter in one photo").font(.seed(size: 40, .heavy)).foregroundStyle(Brand.ink)
            AccentRule()
            feature("bolt.fill", "Hold the camera over the items and tap Ring up. Every pack is named and priced.")
            feature("qrcode", "Customers pay by PromptPay QR or cash, with the total spoken in Thai.")
            feature("chart.bar.xaxis", "Sales, stock, day close and reports stay on this device, even offline.")
        case .camera:
            header("CAMERA", "OneShot sees the counter",
                   "The camera recognises the items you sell. Photos stay on this device unless you sign in to back them up.")
            switch cameraStatus {
            case .authorized:
                Label("Camera allowed", systemImage: "checkmark.circle.fill").font(.seed(.headline)).foregroundStyle(Brand.positive)
            case .denied, .restricted:
                Text("The camera is off for OneShot. Turn it on in Settings › OneShot › Camera.")
                    .font(.seed(.callout)).foregroundStyle(Brand.body)
            default:
                Button("Allow the camera", systemImage: "camera.fill") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
                .primaryButton()
                .controlSize(.large)
            }
        case .shop:
            header("YOUR SHOP", "What is the shop called?", "It goes on receipts and the monthly statement.")
            TextField("Shop name", text: $shopName)
                .textFieldStyle(.roundedBorder).font(.seed(.title3)).focused($typing).submitLabel(.next)
                .onSubmit(next)
        case .promptPay:
            header("PAYMENT", "Where should PromptPay payments go?",
                   "A Thai mobile number, 13-digit ID or e-wallet ID. Customers scan a QR with the amount already filled in.")
            TextField("Mobile, 13-digit ID or e-wallet", text: $draftID)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder).font(.seed(.title3)).focused($typing)
            if PromptPay.looksFinished(draftID), !PromptPay.isValidTarget(draftID) {
                Text("Not a Thai mobile number, 13-digit ID or 15-digit e-wallet ID.")
                    .font(.seed(.caption)).foregroundStyle(Brand.negative)
            }
        case .pin:
            header("REFUNDS", "A PIN for refunds?", "Only someone who knows it can refund a sale. You can set it later in Settings.")
            SecureField("4-digit PIN", text: $pin)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder).font(.seed(.title3)).focused($typing)
        case .products:
            header("PRODUCTS", "What do you sell?", "OneShot learns a product from 8 photos and a price. No retraining.")
            choice("plus.viewfinder", "Teach my first product", "Open the camera and teach it now.") {
                finish(teach: true)
            }
            choice("sparkles", "Try it with 12 sample snacks", "Lay's, KitKat, M&M's and more, the packs OneShot knows already.") {
                app.addSampleProducts()
                next()
            }
            choice("arrow.right", "Start empty", "Add products later from Products or Checkout.") { next() }
        case .account:
            header("ACCOUNT", "Back up and use more devices?",
                   "Sign in to keep a copy of your shop in the cloud and use it on your iPad and iPhone. OneShot works fully without an account.")
            Button("Sign in", systemImage: "person.crop.circle") { signingIn = true }
                .primaryButton().controlSize(.large)
        }
        if let problem {
            Text(problem).font(.seed(.caption)).foregroundStyle(Brand.negative)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }.buttonStyle(.glass)
            }
            Spacer()
            ProgressView(value: Double((steps.firstIndex(of: step) ?? 0) + 1), total: Double(steps.count))
                .frame(maxWidth: 160)
                .tint(Brand.accent)
            Spacer()
            if step != .products {
                Button(primaryTitle) { next() }
                    .primaryButton()
                    .disabled(step == .promptPay && !draftID.isEmpty && !PromptPay.isValidTarget(draftID))
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: "Get started"
        case .account: "Not now"
        case .camera where cameraStatus == .notDetermined: "Skip"
        case .promptPay where draftID.isEmpty: "Skip"
        case .pin where pin.isEmpty: "Skip"
        default: steps.last == step ? "Done" : "Next"
        }
    }

    // MARK: - Pieces

    private func header(_ eyebrow: LocalizedStringKey, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).eyebrow()
            Text(title).font(.seed(.largeTitle, .bold)).foregroundStyle(Brand.ink)
            AccentRule()
            Text(detail).font(.seed(.body)).foregroundStyle(Brand.body)
        }
    }

    private func feature(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).font(.seed(.body)).foregroundStyle(Brand.body) } icon: {
            Image(systemName: icon).foregroundStyle(Brand.accent).frame(width: 28)
        }
    }

    private func choice(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.seed(.title2)).foregroundStyle(Brand.accent).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.seed(.headline)).foregroundStyle(Brand.ink)
                    Text(detail).font(.seed(.subheadline)).foregroundStyle(Brand.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Brand.muted)
            }
            .card(padding: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Moving on

    private func next() {
        problem = nil
        switch step {
        case .promptPay where !draftID.isEmpty:
            promptPayID = draftID
        case .pin where !pin.isEmpty:
            guard RefundPIN.isValid(pin) else {
                problem = String(localized: "The PIN is 4 digits.")
                return
            }
            do {
                try RefundPIN.save(pin)
            } catch {
                problem = error.localizedDescription
                return
            }
        default:
            break
        }
        typing = false
        if step == steps.last { finish(teach: false) } else { move(1) }
    }

    private func move(_ by: Int) {
        guard let index = steps.firstIndex(of: step), steps.indices.contains(index + by) else { return }
        step = steps[index + by]
        if step == .promptPay { draftID = promptPayID }
    }

    private func finish(teach: Bool) {
        UserDefaults.standard.set(true, forKey: OnboardingKey.done)
        if teach { app.startTeaching() }
        onDone()
    }
}
