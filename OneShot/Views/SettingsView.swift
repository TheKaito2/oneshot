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
    #if DEBUG
    static let showsDebug = true
    #else
    static let showsDebug = UserDefaults.standard.bool(forKey: "debugMenu")
    #endif

    @Bindable var app: AppModel
    /// iPhone's Settings tab: nothing to close.
    var inTab = false
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
    @State private var showingAccount = false
    @State private var account = Account.shared
    @State private var sync = SyncEngine.shared
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
                if Cloud.isConfigured {
                    Section {
                        Button { showingAccount = true } label: { accountHeader }
                            .buttonStyle(.plain)
                    }
                    .frostedRows()
                }
                Section("Shop") {
                    NavigationLink { shopPage } label: {
                        IconRow("Shop details", icon: "storefront.fill", tint: Brand.accent,
                            value: maskedID)
                    }
                    NavigationLink { pinPage } label: {
                        IconRow("Refund PIN", icon: "lock.fill", tint: Brand.mauve,
                            value: hasPIN ? String(localized: "On") : String(localized: "Off"))
                    }
                }
                .frostedRows()
                Section("Data") {
                    NavigationLink { backupPage } label: {
                        IconRow("Backup & restore", icon: "externaldrive.fill", tint: Brand.sky)
                    }
                    // ponytail: iOS's own per-app language page; an instant in-app switch only if a shop asks.
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        IconRow("Language", icon: "globe", tint: Brand.sage, value: language, external: true)
                    }
                }
                .frostedRows()
                Section("Help") {
                    NavigationLink { demoPage } label: {
                        IconRow("Demo & sample data", icon: "sparkles", tint: Brand.sand)
                    }
                    NavigationLink { diagnosticsPage } label: {
                        IconRow("Diagnostics", icon: "stethoscope", tint: Brand.muted)
                    }
                    Link(destination: URL(string: "https://oneshot-pos.pages.dev")!) {
                        IconRow("Privacy & support", icon: "hand.raised.fill", tint: Brand.sky, external: true)
                    }
                    NavigationLink { aboutPage } label: {
                        IconRow("About", icon: "info.circle.fill", tint: Brand.muted)
                    }
                }
                .frostedRows()
                // Development builds, and a test build launched with -debugMenu YES; a shop never sees it.
                if Self.showsDebug {
                    Section("Debug") {
                        Toggle("Show speed HUD and save lock photos", isOn: $debugOverlay)
                        Button("Show tips again") { Tips.showAllTipsForTesting() }
                    }
                    .frostedRows()
                }
                Section { versionFooter }
                    .listRowBackground(Color.clear)
            }
            .gridList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !inTab {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        // On the stack, not a page: the dialogs keep working whichever page is showing.
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
        .sheet(isPresented: $showingAccount) { AccountView(app: app) }
        .alert("Turn off the refund PIN?", isPresented: $turningOffPIN) {
            SecureField("Current PIN", text: $pinEntry).keyboardType(.numberPad)
            Button("Turn off", role: .destructive) {
                if RefundPIN.matches(pinEntry) { savePIN(nil) } else { pinProblem = String(localized: "Wrong PIN.") }
                pinEntry = ""
            }
            Button("Cancel", role: .cancel) { pinEntry = "" }
        }
        .onAppear {
            draftID = promptPayID
            hasPIN = RefundPIN.isSet()
        }
        .task { await writeBackup() }
    }

    // MARK: - Root pieces

    /// Apple Settings' account card: who owns this shop and whether it's backed up.
    private var accountHeader: some View {
        HStack(spacing: 14) {
            LogoTile(size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(shopName.isEmpty ? String(localized: "Your shop") : shopName)
                    .font(.seed(.title3, .bold)).foregroundStyle(Brand.ink).lineLimit(1)
                Text(account.email ?? String(localized: "Sign in to back up and sync"))
                    .font(.seed(.subheadline)).foregroundStyle(account.isSignedIn ? Brand.body : Brand.accent).lineLimit(1)
                if account.isSignedIn {
                    Group {
                        if sync.running {
                            Text("Backing up…")
                        } else if let last = sync.lastSynced {
                            Text("Synced \(last, style: .relative) ago")
                        }
                    }
                    .font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Brand.mutedSoft)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    private var maskedID: String {
        promptPayID.isEmpty ? String(localized: "Not set") : "•••\(promptPayID.suffix(4))"
    }

    private var language: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return VStack(spacing: 6) {
            LogoTile(size: 28)
            Text(verbatim: "OneShot \(version) (\(build))").font(.seed(.footnote, .bold)).foregroundStyle(Brand.muted)
            Text("Made in Thailand").font(.seed(.caption)).foregroundStyle(Brand.mutedSoft)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pages

    private func page(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        Form { content() }
            .gridList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var shopPage: some View {
        page("Shop details") {
            Section {
                TextField("Shop name", text: $shopName)
            } header: {
                InfoHeader("Name", info: "It goes on receipts and the monthly statement.")
            }
            .frostedRows()
            Section {
                TextField("Mobile, 13-digit ID or e-wallet", text: $draftID)
                    .keyboardType(.numberPad)
                    // Saved as soon as it's a valid target, like the iOS Settings app: no Save button to miss.
                    .onChange(of: draftID) { _, id in if PromptPay.isValidTarget(id) { promptPayID = id } }
                if PromptPay.looksFinished(draftID), !PromptPay.isValidTarget(draftID) {
                    Text("Not a Thai mobile number, 13-digit ID or 15-digit e-wallet ID.")
                        .font(.seed(.caption)).foregroundStyle(Brand.negative)
                } else if !promptPayID.isEmpty, draftID == promptPayID {
                    Label("Saved", systemImage: "checkmark.circle.fill").font(.seed(.caption)).foregroundStyle(Brand.positive)
                }
            } header: {
                InfoHeader("PromptPay", info: "Customers scan a QR with the amount already filled in, paid straight to this ID.")
            }
            .frostedRows()
        }
    }

    private var pinPage: some View {
        page("Refund PIN") {
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
            } footer: {
                Text(hasPIN
                     ? "Refunds ask for this PIN. To change it, turn it off and set a new one."
                     : "Set a PIN and only someone who knows it can refund a sale.")
            }
            .frostedRows()
        }
    }

    private var backupPage: some View {
        page("Backup & restore") {
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
                InfoHeader("Backup", info: "One folder with sales, refunds, day closes, stock, taught products, prices, barcodes and product photos. Keep it outside OneShot, e.g. in iCloud Drive. Restoring adds the backup's sales to these books.")
            } footer: {
                Text("Restoring replaces products, prices and photos with the backup's.")   // a warning: stays in sight
            }
            .frostedRows()
        }
    }

    private var demoPage: some View {
        page("Demo & sample data") {
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
                InfoHeader("Demo", info: "For presenting without the snacks, or from the simulator. Sample sales can only be added while the books are empty, so they never mix with real ones.")
            }
            .frostedRows()
        }
    }

    private var diagnosticsPage: some View {
        page("Diagnostics") {
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
                InfoHeader("Crash reports", info: "Crash and hang reports from iOS, kept on this device. Share them when asking for help.")
            }
            .frostedRows()
        }
    }

    // The OFL asks for the notice to travel with the font; the full licence is in the app bundle too.
    private var aboutPage: some View {
        page("About") {
            Section {
                VStack(spacing: 10) {
                    LogoTile(size: 72)
                    Text(verbatim: "OneShot").font(.seed(.title2, .bold)).foregroundStyle(Brand.ink)
                    Text("One-tap checkout for Thai shops.").font(.seed(.subheadline)).foregroundStyle(Brand.body)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            Section("Licences") {
                LabeledContent("Font", value: "LINE Seed Sans TH")
                Text("© LY Corporation. SIL Open Font License 1.1.").font(.seed(.caption)).foregroundStyle(Brand.muted)
            }
            .frostedRows()
        }
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
