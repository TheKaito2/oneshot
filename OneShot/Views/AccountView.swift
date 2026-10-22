import AuthenticationServices
import SwiftData
import SwiftUI

/// Sign in with an emailed code, sign out, or delete the account. Signed in, the shop is backed up and synced to the
/// owner's other devices; signed out, everything keeps working on this device.
struct AccountView: View {
    @Bindable var app: AppModel
    @State private var account = Account.shared
    @State private var sync = SyncEngine.shared
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var offeringErase = false
    /// Just signed in on this screen: the confirmation shows until it's closed.
    @State private var justSignedIn = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let signedIn = account.email {
                    if justSignedIn {
                        Section {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(Brand.positive)
                                    .symbolEffect(.bounce, value: justSignedIn)
                                Text("You're signed in").font(.seed(.title3, .bold)).foregroundStyle(Brand.ink)
                                Text(sync.running ? "Backing up your shop…" : sync.lastSynced != nil ? "Your shop is backed up." : "Your shop backs up in a moment.")
                                    .font(.seed(.subheadline)).foregroundStyle(Brand.body)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                        }
                        .frostedRows()
                    }
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
                } else {
                    Section {
                        SignInButtons(onSignedIn: signedInNow)
                    } footer: {
                        Text("Back up the shop and use it on your other devices.")
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
            .sensoryFeedback(.success, trigger: justSignedIn) { _, now in now }
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

    private func signedInNow() {
        withAnimation(.spring) { justSignedIn = true }
        Task { await sync.sync(app) }   // the first backup starts now, and the card shows it
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return   // the sheet was closed: nothing to report
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Sign in with Apple and with Google, shared by Account and onboarding. Apple's button comes first (guideline 4.8).
struct SignInButtons: View {
    let onSignedIn: () -> Void
    @State private var account = Account.shared
    /// The nonce for the Apple request in flight; its hash went into the request.
    @State private var appleNonce = ""
    @State private var busy = false
    @State private var problem: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.continue) { request in
                appleNonce = AppleNonce.make()
                request.requestedScopes = [.email]
                request.nonce = AppleNonce.sha256(appleNonce)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                        problem = String(localized: "Apple didn't return a sign-in token. Try again.")
                        return
                    }
                    let nonce = appleNonce
                    run { try await account.signInWithApple(idToken: token, nonce: nonce) }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled { problem = error.localizedDescription }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(.capsule)
            Button {
                run { try await account.signInWithGoogle() }
            } label: {
                Label("Continue with Google", systemImage: "globe")
                    .font(.seed(.headline))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            if let problem {
                Text(problem).font(.seed(.caption)).foregroundStyle(Brand.negative)
            }
        }
        .disabled(busy)
        .padding(.vertical, 4)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                onSignedIn()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return   // the sheet was closed: nothing to report
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
