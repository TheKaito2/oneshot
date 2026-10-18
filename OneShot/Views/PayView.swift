import AVFoundation
import SwiftUI

/// Pay by PromptPay QR or cash. The total is spoken in Thai; with cash, so is the change.
/// "Turn to customer" flips what the customer needs (total, QR, change) for the person across the counter.
struct PayView: View {
    let total: Decimal
    /// For the receipt's product names in the app's language.
    let catalog: Catalog
    /// Records the sale; returns it for the receipt (nil if logging failed: the sale still ends).
    let onPaid: (PaymentMethod, Decimal?) -> Sale?
    /// Next customer.
    let onDone: () -> Void

    @AppStorage(SettingsKey.promptPayID) private var promptPayID = ""
    @State private var method: PaymentMethod = .promptPay
    @State private var received: Decimal?
    @State private var receivedText = ""
    @State private var facingCustomer = false
    @State private var draftID = ""
    @State private var voice = CounterVoice()
    /// Made once per PromptPay number, not on every render (it built a new CIContext up to 3 times a pass).
    @State private var qr: CGImage?
    @State private var receipt: Sale?
    @State private var notSaved = false
    /// A field has the keyboard: scroll so it and Paid sit above it.
    @FocusState private var typing: Bool
    @AppStorage(SettingsKey.shopName) private var shopName = ""
    @Environment(\.dismiss) private var dismiss


    private var canFinish: Bool {
        switch method {
        case .promptPay: qr != nil
        case .cash: (received ?? 0) >= total
        }
    }

    var body: some View {
        NavigationStack {
            if let receipt {
                done(receipt)
            } else {
                paying
            }
        }
        .onAppear { voice.say(ThaiVoice.totalPhrase(total)) }
        .onDisappear { voice.stop() }   // closed mid-sentence, the music came back only after the next payment
        .alert("Paid, but not saved to the books", isPresented: $notSaved) {
            Button("OK", action: onDone)
        } message: {
            Text("Write this sale down (\(total.baht)) and add it later. Stock was not changed.")
        }
        .task(id: promptPayID) {
            qr = (try? PromptPay.payload(target: promptPayID, amount: total)).flatMap { PromptPay.qrImage($0) }
        }
    }

    /// After Paid, like Square's: the outcome, the receipt to share or print, and the way to the next customer.
    private func done(_ sale: Sale) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Brand.positive)
                    .symbolEffect(.bounce, value: sale.id)
                Text("Paid \(sale.total.baht)").font(.seed(.largeTitle, .bold))
                if let change = sale.change, change > 0 {
                    Text("Change \(change.baht)").font(.seed(.title2, .bold)).foregroundStyle(Brand.positive)
                }
                ReceiptView(sale: sale, shopName: shopName, catalog: catalog)
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                HStack {
                    if let image = ReceiptView.image(sale, shopName: shopName, catalog: catalog) {
                        ShareLink(item: image, preview: SharePreview("Receipt", image: image)) {
                            Label("Share or print", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                    }
                    Button("New sale", systemImage: "bolt.fill", action: onDone)
                        .primaryButton()
                }
                .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(GridBackground())
    }

    private var paying: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    customerPanel
                        .frame(maxWidth: 640)   // a QR-sized panel, not a full-width slab in landscape
                        .rotationEffect(.degrees(facingCustomer ? 180 : 0))
                        .animation(.spring, value: facingCustomer)
                    Picker("Payment", selection: $method) {
                        Text("PromptPay").tag(PaymentMethod.promptPay)
                        Text("Cash").tag(PaymentMethod.cash)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    if method == .cash {
                        cashControls
                    } else if qr == nil {
                        idEntry
                    }
                    HStack {
                        Button("Say it again", systemImage: "speaker.wave.2.fill") { speakAgain() }
                            .buttonStyle(.glass)
                        Button("Paid", systemImage: "checkmark.circle.fill") { finish() }
                            .primaryButton()
                            .disabled(!canFinish)
                    }
                    .controlSize(.large)
                    .id("actions")
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            // Centred while it fits; scrollable once the keyboard takes the bottom half.
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            // On the keyboard's arrival, not on focus: only then has the scroll view's inset made room.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if typing { withAnimation { proxy.scrollTo("actions", anchor: .bottom) } }
            }
        }
        .background(GridBackground())
        .navigationTitle("Pay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $facingCustomer) {
                    Label("Turn to customer", systemImage: "rotate.right")
                }
                .toggleStyle(.button)
            }
        }
    }

    private func finish() {
        let sale = onPaid(method, method == .cash ? received : nil)
        if let sale {
            withAnimation(.spring) { receipt = sale }
        } else {
            notSaved = true
        }
    }

    /// What the customer reads: the total, then the QR or the change.
    private var customerPanel: some View {
        VStack(spacing: 12) {
            Text(total.baht).font(.seed(size: 56, .heavy)).foregroundStyle(Brand.ink)
            switch method {
            case .promptPay:
                if let qr {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 340, maxHeight: 340)
                        .padding(16)
                        .background(.white, in: .rect(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        .accessibilityLabel("PromptPay QR for \(total.baht)")
                    Text("PromptPay · ••••\(String(promptPayID.filter(\.isNumber).suffix(4)))")
                        .font(.seed(.subheadline))
                        .foregroundStyle(Brand.body)
                }
            case .cash:
                if let received {
                    Text("Received \(received.baht)").font(.seed(.title3, .regular)).foregroundStyle(Brand.body)
                    Text("Change \((received - total).baht)")
                        .font(.seed(size: 48, .extraBold))
                        .foregroundStyle(Brand.positive)
                }
            }
        }
        .card(padding: 24, alignment: .center)   // centred: the default leading alignment pushed the QR hard left
    }

    private var cashControls: some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 10) {
                HStack {
                    ForEach(Cash.suggestions(for: total), id: \.self) { amount in
                        Button(amount == total ? String(localized: "Exact") : amount.baht) { take(amount) }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                    }
                }
            }
            TextField("Cash received", text: $receivedText)
                .keyboardType(.decimalPad)
                .focused($typing)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                // Counts as it's typed: Paid used to stay grey until Return, or record an earlier chip amount.
                .onChange(of: receivedText) { _, text in
                    guard !text.isEmpty else { return }   // a chip clears the field; its amount stays
                    // Too little or not a number: no amount, so Paid waits (a corrected '20' used to keep an earlier 100).
                    received = Decimal(baht: text).flatMap { $0 >= total ? $0 : nil }
                }
                .onSubmit {
                    if let amount = Decimal(baht: receivedText), amount >= total { take(amount) }
                }
        }
    }

    /// First run only; Settings › Payment changes it later.
    private var idEntry: some View {
        VStack(spacing: 8) {
            Text("Enter the shop's PromptPay number once").font(.seed(.headline))
            TextField("Mobile, 13-digit ID or e-wallet", text: $draftID)
                .keyboardType(.numberPad)
                .focused($typing)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            if PromptPay.looksFinished(draftID), !PromptPay.isValidTarget(draftID) {
                Text("Not a Thai mobile number, 13-digit ID or 15-digit e-wallet ID.")
                    .font(.seed(.caption))
                    .foregroundStyle(Brand.negative)
            }
            Button("Save") { promptPayID = draftID }
                .primaryButton()
                .disabled(!PromptPay.isValidTarget(draftID))
        }
    }

    private func take(_ amount: Decimal) {
        received = amount
        receivedText = ""
        voice.say(ThaiVoice.changePhrase(received: amount, total: total))
    }

    private func speakAgain() {
        if method == .cash, let received {
            voice.say(ThaiVoice.changePhrase(received: received, total: total))
        } else {
            voice.say(ThaiVoice.totalPhrase(total))
        }
    }
}

/// The spoken total and change, always Thai (Kanya, the best quality installed), whatever the screen language.
/// Shop music dips while it speaks and comes back after (it used to stay quiet after the first payment).
final class CounterVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("audio session: \(error)")
        }
        let utterance = AVSpeechUtterance(string: text)
        // The best Thai voice installed: Kanya (Enhanced), a free download in Settings › Accessibility › Spoken Content
        // › Voices › Thai, sounds far more natural than the compact Kanya that `AVSpeechSynthesisVoice(language:)` returns.
        utterance.voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "th-TH" }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "th-TH")
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// Ducking lasts while the session is active, so it ends by deactivating (other audio told to come back up).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        release()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        release()
    }

    private func release() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("audio session: \(error)")
        }
        AudioMode.mixed()
    }
}

/// Chimes and speech play even with the Silent switch on (the iPad has no haptics; sound is the feedback), mixed
/// over whatever the shop is playing.
enum AudioMode {
    static func mixed() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        } catch {
            print("audio session: \(error)")
        }
    }
}
