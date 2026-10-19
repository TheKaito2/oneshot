import SwiftData
import SwiftUI
import TipKit
import UniformTypeIdentifiers

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
    @State private var backup: URL?
    @State private var backupProblem: String?
    @State private var exporting = false
    @State private var importing = false
    /// The picked backup folder and what it holds, waiting for the owner's OK.
    @State private var restoring: (url: URL, summary: Store.BackupSummary)?
    @State private var restoreNote: String?
    @State private var addingSamples = false
    @State private var sampleNote: String?
    /// Sample sales are only offered on empty books.
    @Query private var sales: [SaleRecord]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
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
                    Button("Back up…", systemImage: "externaldrive") { exporting = true }
                        .disabled(backup == nil)
                    Button("Restore from a backup…", systemImage: "arrow.counterclockwise") { importing = true }
                    if let backupProblem {
                        Text("Backup failed: \(backupProblem)").font(.seed(.caption)).foregroundStyle(Brand.negative)
                    }
                    if let restoreNote {
                        Text(restoreNote).font(.seed(.caption)).foregroundStyle(Brand.muted)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("One folder with sales, refunds, day closes, stock, taught products, prices, barcodes and product photos. Keep it outside OneShot, e.g. in iCloud Drive. Restoring adds the backup's sales to these books and replaces products, prices and photos with the backup's.")
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
                        // On the button, so the iPad popover points at it (it hung from the top of the screen).
                        .confirmationDialog("Add two weeks of sample sales?", isPresented: $addingSamples, titleVisibility: .visible) {
                            Button("Add sample sales") { addSamples() }
                        } message: {
                            Text("Made-up sales fill Home and Reports for a demo. Delete the app to remove them.")
                        }
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
                Section {
                    let reports = Diagnostics.files()
                    if reports.isEmpty {
                        Text("No reports yet.").foregroundStyle(Brand.muted)
                    } else {
                        ShareLink(items: reports) {
                            Label("Share \(reports.count) reports", systemImage: "stethoscope")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Crash and hang reports from iOS, kept on this device. Share them when asking for help.")
                }
                .frostedRows()
                // The OFL asks for the notice to travel with the font; the full licence is in the app bundle too.
                Section("About") {
                    Link("Privacy and support", destination: URL(string: "https://oneshot-pos.pages.dev")!)
                    LabeledContent("Font", value: "LINE Seed Sans TH")
                    Text("© LY Corporation. SIL Open Font License 1.1.").font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
                .frostedRows()
            }
            .gridList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileExporter(isPresented: $exporting, document: backup.map(BackupFolder.init), contentType: .folder,
                          defaultFilename: String(localized: "OneShot Backup \(Date.now.formatted(.iso8601.year().month().day()))")) { result in
                if case .failure(let error) = result { backupProblem = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let summary = Store.summary(of: url)
                    if summary == Store.BackupSummary() {
                        restoreNote = String(localized: "That folder isn't a OneShot backup.")
                    } else {
                        restoring = (url, summary)
                    }
                case .failure(let error):
                    restoreNote = error.localizedDescription
                }
            }
            .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                                titleVisibility: .visible, presenting: restoring) { pending in
                Button("Restore") { restore(pending.url) }
            } message: { pending in
                Text("\(pending.summary.sales) sales, \(pending.summary.closes) day closes, \(pending.summary.products) taught products, \(pending.summary.photos) photos. Products, prices and photos on this device are replaced.")
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
        let folder = URL.temporaryDirectory.appending(path: "Backup", directoryHint: .isDirectory)
        do {
            try await Task.detached {
                try? FileManager.default.removeItem(at: folder)   // last visit's: a deleted photo must not come back
                _ = try Store.backUp(container, to: folder)
            }.value
            backup = folder
            backupProblem = nil
        } catch {
            backup = nil
            backupProblem = error.localizedDescription
        }
    }

    private func restore(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try Store.restore(from: url, into: context)
            app.reloadCatalog()
            app.gallery.reload()
            restoreNote = String(localized: "Backup restored.")
            Task { await writeBackup() }
        } catch {
            restoreNote = error.localizedDescription
        }
    }
}

/// A backup folder, for `fileExporter`: written as it is, wherever the owner picks.
struct BackupFolder: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    let url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }   // export only

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url) }
}
