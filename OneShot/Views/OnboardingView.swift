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
    /// Which way the pages slide.
    @State private var forward = true
    @State private var account = Account.shared
    @FocusState private var typing: Bool

    /// The account step only exists in a build that has a backend to sign in to.
    private var steps: [Step] { Step.allCases.filter { $0 != .account || Cloud.isConfigured } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    content
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                                        removal: .move(edge: forward ? .leading : .trailing)).combined(with: .opacity))
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.center, for: .alignment)
            footer
        }
        .background(GridBackground())
        .animation(.smooth(duration: 0.35), value: step)
    }

    // MARK: - Top bar and hero

    /// Back on the left, one capsule per step in the middle, Skip on the right (Duolingo, Revolut).
    private var topBar: some View {
        HStack(spacing: 14) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).contentShape(.rect)
            }
            .foregroundStyle(Brand.ink)
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)
            .accessibilityLabel("Back")
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { each in
                    Capsule()
                        .fill(each.rawValue <= step.rawValue ? Brand.accent : Brand.hairline)
                        .frame(height: 5)
                }
            }
            .frame(maxWidth: 360)
            .accessibilityElement()
            .accessibilityLabel(Text("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)"))
            Button("Skip") { skip() }
                .font(.seed(.callout, .bold))
                .foregroundStyle(Brand.muted)
                .frame(minWidth: 44, minHeight: 44)
                .opacity(skippable ? 1 : 0)
                .disabled(!skippable)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Optional steps; Skip leaves what was typed unsaved. The account step has its own Not now.
    private var skippable: Bool { [.camera, .promptPay, .pin].contains(step) }

    @ViewBuilder
    private var hero: some View {
        if step == .welcome {
            LogoTile(size: 112).shadow(color: Brand.accent.opacity(0.35), radius: 24, y: 10).padding(.top, 24)
        } else {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Brand.accent)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 120, height: 120)
                .background(Brand.card, in: .circle)
                .overlay(Circle().strokeBorder(Brand.hairline))
                .padding(.top, 24)
                .accessibilityHidden(true)
        }
    }

    private var icon: String {
        switch step {
        case .welcome: "bolt.fill"
        case .camera: "camera.viewfinder"
        case .shop: "storefront"
        case .promptPay: "qrcode"
        case .pin: "lock.shield"
        case .products: "shippingbox"
        case .account: "icloud.and.arrow.up"
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            title("Scan the whole counter in one photo",
                  "Hold the camera over the items and tap Scan. Every pack is named and priced.")
            VStack(alignment: .leading, spacing: 16) {
                feature("viewfinder", "One tap scans every item in view.")
                feature("qrcode", "PromptPay QR or cash, with the total spoken in Thai.")
                feature("chart.bar.xaxis", "Sales, stock and reports work offline.")
            }
            .card(padding: 20)
        case .camera:
            title("OneShot sees the counter",
                  "The camera recognises the items you sell. Photos stay on this device unless you sign in to back them up.")
            switch cameraStatus {
            case .authorized:
                Label("Camera allowed", systemImage: "checkmark.circle.fill").font(.seed(.headline)).foregroundStyle(Brand.positive)
            case .denied, .restricted:
                Text("The camera is off for OneShot. Turn it on in Settings › OneShot › Camera.")
                    .font(.seed(.callout)).foregroundStyle(Brand.body).multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        case .shop:
            title("What is the shop called?", "It goes on receipts and the monthly statement.")
            field { TextField("Shop name", text: $shopName).submitLabel(.next).onSubmit(next) }
        case .promptPay:
            title("Where should PromptPay payments go?",
                  "A Thai mobile number, 13-digit ID or e-wallet ID. Customers scan a QR with the amount already filled in.")
            field { TextField("Mobile, 13-digit ID or e-wallet", text: $draftID).keyboardType(.numberPad) }
            if PromptPay.looksFinished(draftID), !PromptPay.isValidTarget(draftID) {
                Text("Not a Thai mobile number, 13-digit ID or 15-digit e-wallet ID.")
                    .font(.seed(.caption)).foregroundStyle(Brand.negative)
            }
        case .pin:
            title("A PIN for refunds?", "Only someone who knows it can refund a sale. You can set it later in Settings.")
            field { SecureField("4-digit PIN", text: $pin).keyboardType(.numberPad) }
        case .products:
            title("What do you sell?", "OneShot learns a product from 8 photos and a price. No retraining.")
            VStack(spacing: 12) {
                choice("plus.viewfinder", "Teach my first product", "Open the camera and teach it now.") {
                    finish(teach: true)
                }
                choice("sparkles", "Try it with 12 sample snacks", "Common Thai shop snacks that OneShot knows already.") {
                    app.addSampleProducts()
                    next()
                }
                choice("arrow.right", "Start empty", "Add products later from Products or Checkout.") { next() }
            }
        case .account:
            title("Back up and use more devices?",
                  "Sign in to keep a copy of your shop in the cloud and use it on your iPad and iPhone. OneShot works fully without an account.")
            if account.isSignedIn {
                Label("You're signed in", systemImage: "checkmark.circle.fill")
                    .font(.seed(.headline)).foregroundStyle(Brand.positive)
                    .symbolEffect(.bounce, value: account.isSignedIn)
            } else {
                SignInButtons { Task { await SyncEngine.shared.sync(app) } }
            }
        }
        if let problem {
            Text(problem).font(.seed(.caption)).foregroundStyle(Brand.negative)
        }
    }

    /// One full-width primary action, pinned to the bottom. The products step's cards are its actions.
    private var footer: some View {
        VStack {
            if step == .account, !account.isSignedIn {
                Button("Not now") { next() }
                    .font(.seed(.headline))
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else if step != .products {
                Button { primaryAction() } label: {
                    Text(primaryTitle).font(.seed(.headline)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .primaryButton()
                .controlSize(.large)
                .disabled(step == .promptPay && !draftID.isEmpty && !PromptPay.isValidTarget(draftID))
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: "Get started"
        case .camera where cameraStatus == .notDetermined: "Allow the camera"
        default: steps.last == step ? "Done" : "Continue"
        }
    }

    private func primaryAction() {
        guard step == .camera, cameraStatus == .notDetermined else { return next() }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    // MARK: - Pieces

    private func title(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.seed(size: 32, .heavy, relativeTo: .largeTitle)).foregroundStyle(Brand.ink)
            Text(detail).font(.seed(.body)).foregroundStyle(Brand.body)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A large text field on a card, the way Revolut and Cash App ask for one thing at a time.
    private func field(@ViewBuilder _ input: () -> some View) -> some View {
        input()
            .font(.seed(.title3))
            .focused($typing)
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(Brand.card, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(typing ? Brand.accent : Brand.hairline,
                                                                                          lineWidth: typing ? 2 : 1))
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

    /// Leaves the step without saving what was typed in it.
    private func skip() {
        problem = nil
        typing = false
        if step == steps.last { finish(teach: false) } else { move(1) }
    }

    private func move(_ by: Int) {
        guard let index = steps.firstIndex(of: step), steps.indices.contains(index + by) else { return }
        forward = by > 0
        step = steps[index + by]
        if step == .promptPay { draftID = promptPayID }
    }

    private func finish(teach: Bool) {
        UserDefaults.standard.set(true, forKey: OnboardingKey.done)
        if teach { app.startTeaching() }
        onDone()
    }
}
