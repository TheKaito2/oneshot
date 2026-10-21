import SwiftData
import SwiftUI

/// Sign in with an emailed code, sign out, or delete the account. Signed in, the shop is backed up and synced to the
/// owner's other devices; signed out, everything keeps working on this device.
struct AccountView: View {
    @Bindable var app: AppModel
    @State private var account = Account.shared
    @State private var sync = SyncEngine.shared
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var usePassword = false
    @State private var password = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var offeringErase = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let signedIn = account.email {
                    Section {
                        LabeledContent("Signed in as", value: signedIn)
                        Button("Sign out") { run { try await account.signOut() } }
                    } footer: {
                        Text("Signing out keeps the shop on this device.")
                    }
                    .frostedRows()
                    Section {
                        if let last = sync.lastSynced {
                            LabeledContent("Last synced") { Text(last, style: .relative) }
                        }
                        if sync.pending > 0 {
                            LabeledContent("Waiting to sync", value: "\(sync.pending)")
                        }
                        if let trouble = sync.problem {
                            Text(trouble).font(.seed(.caption)).foregroundStyle(Brand.negative)
                        }
                        Button(sync.running ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await sync.sync(app) }
                        }
                        .disabled(sync.running)
                    } header: {
                        Text("Backup and sync")
                    } footer: {
                        Text("The shop is backed up and kept the same on every device you sign in on. The till never waits for it.")
                    }
                    .frostedRows()
                    Section {
                        Button("Delete account", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Deletes your account and the shop's copy on our server: products, sales, day closes, stock and photos.")
                    }
                    .frostedRows()
                } else if !codeSent {
                    Section {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress).textContentType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if usePassword {
                            SecureField("Password", text: $password).textContentType(.password)
                            Button("Sign in") {
                                run {
                                    try await account.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                                    dismiss()
                                }
                            }
                            .disabled(!email.contains("@") || password.isEmpty || busy)
                        } else {
                            Button("Email me a code") {
                                run {
                                    try await account.sendCode(to: email.trimmingCharacters(in: .whitespaces))
                                    codeSent = true
                                }
                            }
                            .disabled(!email.contains("@") || busy)
                        }
                        Button(usePassword ? "Use an emailed code instead" : "Use a password instead") { usePassword.toggle() }
                            .font(.seed(.footnote))
                    } footer: {
                        Text("Back up the shop and use it on your other devices. No password: we email you a code.")
                    }
                    .frostedRows()
                } else {
                    Section {
                        TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Sign in") {
                            run {
                                try await account.verify(email: email.trimmingCharacters(in: .whitespaces), code: code)
                                dismiss()
                            }
                        }
                        .disabled(code.count < 6 || busy)
                        Button("Use a different email") { codeSent = false; code = "" }
                    } footer: {
                        Text("We sent a code to \(email).")
                    }
                    .frostedRows()
                }
                if let problem {
                    Text(problem).font(.seed(.caption)).foregroundStyle(Brand.negative)
                }
            }
            .gridList()
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .disabled(busy)
            .onAppear { sync.countPending() }
            .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    run {
                        try await account.deleteAccount()
                        offeringErase = true
                    }
                }
            } message: {
                Text("Your account and the shop's copy on our server are deleted for good.")
            }
            .alert("Account deleted", isPresented: $offeringErase) {
                Button("Erase this device", role: .destructive) {
                    do {
                        try Store.eraseEverything(in: context)
                        app.reloadCatalog()
                        app.stock = StockBook.load(from: context)
                        app.gallery.reload()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                Button("Keep on this device", role: .cancel) {}
            } message: {
                Text("The shop is still on this device. Erase it too?")
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
