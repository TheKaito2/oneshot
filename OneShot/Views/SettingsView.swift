import SwiftData
import SwiftUI
import TipKit

enum SettingsKey {
    static let promptPayID = "promptPayID"
    static let debugOverlay = "debugOverlay"  // HUD + calibration dumps
    static let shopName = "shopName"
}

struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage(SettingsKey.promptPayID) private var promptPayID = ""
    @AppStorage(SettingsKey.debugOverlay) private var debugOverlay = false
    @AppStorage(SettingsKey.shopName) private var shopName = ""
    @State private var draftID = ""
    @State private var hasPIN = false
    @State private var newPIN = ""
    @State private var turningOffPIN = false
    @State private var pinEntry = ""
    @State private var pinProblem: String?
    @State private var backup: [URL] = []
    @State private var backupProblem: String?
    @State private var addingSamples = false
    @State private var sampleNote: String?
    /// Sample sales are only offered on empty books.
    @Query private var sales: [SaleRecord]
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Shop") {
                    TextField("Shop name", text: $shopName)
                }
                .frostedRows()
                Section("Payment") {
                    TextField("PromptPay: mobile, 13-digit ID or e-wallet", text: $draftID)
                        .keyboardType(.numberPad)
                    if PromptPay.looksFinished(draftID), !PromptPay.isValidTarget(draftID) {
                        Text("Not a Thai mobile number, 13-digit ID or 15-digit e-wallet ID.")
                            .font(.seed(.caption))
                            .foregroundStyle(Brand.negative)
                    }
                    Button("Save") { promptPayID = draftID }
                        .disabled(!PromptPay.isValidTarget(draftID) || draftID == promptPayID)
                }
                .frostedRows()
                Section {
                    if hasPIN {
                        Button("Turn off the refund PIN", role: .destructive) { turningOffPIN = true }
                    } else {
                        SecureField("4-digit PIN", text: $newPIN)
                            .keyboardType(.numberPad)
                        Button("Set refund PIN") { savePIN(newPIN) }
                            .disabled(!RefundPIN.isValid(newPIN))
                    }
                    if let pinProblem {
                        Text(pinProblem).font(.seed(.caption)).foregroundStyle(Brand.negative)
                    }
                } header: {
                    Text("Refunds")
                } footer: {
                    Text(hasPIN
                         ? "Refunds ask for this PIN. To change it, turn it off and set a new one."
                         : "Set a PIN and only someone who knows it can refund a sale.")
                }
                .frostedRows()
                Section {
                    if !backup.isEmpty {
                        ShareLink(items: backup) { Label("Back up the books", systemImage: "externaldrive") }
                    }
                    if let backupProblem {
                        Text("Backup failed: \(backupProblem)").font(.seed(.caption)).foregroundStyle(Brand.negative)
                    }
                } header: {
                    Text("Books")
                } footer: {
                    Text("Sales, refunds, day closes and stock as 3 files. Keep them outside OneShot, e.g. in iCloud Drive. To put them back, copy them into OneShot's folder in the Files app, then close OneShot in the app switcher and open it again.")
                }
                .frostedRows()
                Section {
                    // ponytail: iOS's own per-app language page; an instant in-app switch only if the demo needs it.
                    Button("Language: English / ไทย") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("The spoken total is always Thai.")
                }
                .frostedRows()
                Section {
                    Toggle("Demo camera: table photos instead of the camera", isOn: $app.demo)
                    Button("Add two weeks of sample sales") { addingSamples = true }
                        .disabled(!sales.isEmpty)
                    if let sampleNote {
                        Text(sampleNote).font(.seed(.caption)).foregroundStyle(Brand.muted)
                    }
                } header: {
                    Text("Demo")
                } footer: {
                    Text("For presenting without the snacks, or from the simulator. Sample sales can only be added while the books are empty, so they never mix with real ones.")
                }
                .frostedRows()
                Section("Debug") {
                    Toggle("Show speed HUD and save lock photos", isOn: $debugOverlay)
                    // Before each new judge.
                    Button("Show tips again") { Tips.showAllTipsForTesting() }
                }
                .frostedRows()
                // The OFL asks for the notice to travel with the font; the full licence is in the app bundle too.
                Section("About") {
                    LabeledContent("Font", value: "LINE Seed Sans TH")
                    Text("© LY Corporation. SIL Open Font License 1.1.").font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
                .frostedRows()
            }
            .gridList()
            .navigationTitle("Settings")
            .confirmationDialog("Add two weeks of sample sales?", isPresented: $addingSamples, titleVisibility: .visible) {
                Button("Add sample sales") { addSamples() }
            } message: {
                Text("Made-up sales fill Home and Reports for a demo. Delete the app to remove them.")
            }
            .alert("Turn off the refund PIN?", isPresented: $turningOffPIN) {
                SecureField("Current PIN", text: $pinEntry).keyboardType(.numberPad)
                Button("Turn off", role: .destructive) {
                    if RefundPIN.matches(pinEntry) { savePIN(nil) } else { pinProblem = String(localized: "Wrong PIN.") }
                    pinEntry = ""
                }
                Button("Cancel", role: .cancel) { pinEntry = "" }
            }
        }
        .onAppear {
            draftID = promptPayID
            hasPIN = RefundPIN.isSet()
        }
        .task { await writeBackup() }
    }

    private func addSamples() {
        do {
            let count = try SampleSales.fill(catalog: app.catalog, in: context)
            sampleNote = String(localized: "Added \(count) sample sales.")
            Task { await writeBackup() }   // the backup on this page would otherwise miss them
        } catch {
            sampleNote = error.localizedDescription
        }
    }

    private func savePIN(_ pin: String?) {
        do {
            try RefundPIN.save(pin)
            pinProblem = nil
        } catch {
            pinProblem = error.localizedDescription
        }
        newPIN = ""
        hasPIN = RefundPIN.isSet()
    }

    /// Written on every visit (nothing changes the books while Settings is showing), off the main thread.
    private func writeBackup() async {
        let container = context.container
        do {
            backup = try await Task.detached { try Store.backUp(container, to: .temporaryDirectory.appending(path: "Backup")) }.value
            backupProblem = nil
        } catch {
            backup = []
            backupProblem = error.localizedDescription
        }
    }
}
