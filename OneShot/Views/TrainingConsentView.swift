import SwiftUI

/// Turning "Help improve OneShot" on or off, the same from Settings and from Home's one-time card.
@MainActor
enum TrainingConsent {
    /// On: the server records the consent first, then this device starts keeping photos. Off: nothing waiting is sent,
    /// and everything already sent is deleted. Returns how many sent photos were deleted.
    @discardableResult
    static func set(_ on: Bool) async throws -> Int {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: TrainingSamples.askedKey)
        if !on {
            defaults.set(false, forKey: TrainingSamples.optInKey)   // stop keeping at once, even offline
            defaults.set(true, forKey: TrainingSamples.withdrawPendingKey)   // until the server confirms
            TrainingSamples.clearWaiting()
        }
        let deleted = try await SyncEngine.shared.setTrainingConsent(on)
        if on {
            defaults.set(false, forKey: TrainingSamples.withdrawPendingKey)
            defaults.set(true, forKey: TrainingSamples.optInKey)
        } else {
            defaults.set(false, forKey: TrainingSamples.withdrawPendingKey)
        }
        return deleted
    }
}

/// Settings › Help improve OneShot: what's shared, in plain words, and the switch.
struct TrainingConsentView: View {
    let app: AppModel
    @AppStorage(TrainingSamples.optInKey) private var optIn = false
    @State private var account = Account.shared
    @State private var busy = false
    @State private var note: String?
    @State private var waiting = 0
    @AppStorage("training.sentTotal") private var sent = 0

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { optIn }, set: { change($0) })) {
                    IconRow("Share photos to improve OneShot", icon: "sparkles", tint: Brand.sage)
                }
                .disabled(busy || !account.isSignedIn)
                if let note {
                    Text(note).font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
            } footer: {
                Text("Off unless you turn it on. Turning it off deletes every photo already sent.")
            }
            .frostedRows()
            if !account.isSignedIn {
                Section {
                    SignInButtons {}
                } footer: {
                    Text("Sign in first, so the photos belong to your account and you can delete them at any time.")
                }
                .frostedRows()
            }
            Section("What happens") {
                point("camera.viewfinder", Brand.accent, "After each paid sale, the counter photo and the items you confirmed are kept.")
                point("face.dashed", Brand.mauve, "Faces are blurred on this device before anything is sent.")
                point("wifi", Brand.sky, "Sent on Wi-Fi only, at most 50 photos a day. Never prices, shop name or payment details.")
                point("lock.shield", Brand.sage, "Only the OneShot developer sees them, to train OneShot's own recognition. Never sold, shared, or sent to other AI services.")
                point("calendar", Brand.sand, "Kept up to 2 years, or until you turn this off or delete your account.")
            }
            .frostedRows()
            if optIn || waiting > 0 || sent > 0 {
                Section {
                    LabeledContent("Waiting for Wi-Fi", value: "\(waiting)")
                    LabeledContent("Sent", value: "\(sent)")
                }
                .frostedRows()
            }
            Section {
                Link(destination: URL(string: "https://oneshot-pos.pages.dev/#training")!) {
                    IconRow("Privacy policy", icon: "hand.raised.fill", tint: Brand.sky, external: true)
                }
            }
            .frostedRows()
        }
        .gridList()
        .navigationTitle("Help improve OneShot")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task { waiting = TrainingSamples.waiting().count }
    }

    private func point(_ icon: String, _ tint: Color, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(icon: icon, tint: tint)
            Text(text).font(.seed(.callout)).foregroundStyle(Brand.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func change(_ on: Bool) {
        busy = true
        note = nil
        Task {
            defer {
                busy = false
                waiting = TrainingSamples.waiting().count
            }
            do {
                let deleted = try await TrainingConsent.set(on)
                note = on ? String(localized: "Thank you. Photos are kept from your next sale.")
                          : String(localized: "Turned off. Deleted \(deleted) photos from our server.")
            } catch {
                note = error.localizedDescription
            }
        }
    }
}

/// Home's one-time ask, after a few sales: a plain question, Allow or Not now, and the details behind ⓘ.
struct TrainingAskCard: View {
    let onAnswer: () -> Void
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Help improve OneShot?", icon: "sparkles",
                       info: "After each paid sale, the counter photo (faces blurred on this device) and the items you confirmed are sent on Wi-Fi, at most 50 a day, to train OneShot's own recognition. Never prices or payment details. Kept up to 2 years; turn it off in Settings any time and they're deleted.")
            Text("Share counter photos from your sales so OneShot recognises more products. Off unless you allow it.")
                .font(.seed(.callout))
                .foregroundStyle(Brand.body)
            if let problem {
                Text(problem).font(.seed(.caption)).foregroundStyle(Brand.negative)
            }
            HStack {
                Button("Not now") {
                    UserDefaults.standard.set(true, forKey: TrainingSamples.askedKey)
                    onAnswer()
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Allow") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await TrainingConsent.set(true)
                            onAnswer()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .primaryButton()
            }
            .controlSize(.large)
            .disabled(busy)
        }
        .card(padding: 18)
    }
}
