import SwiftUI

/// The stage timer over the scan zone: GO (in step with the cashier video) starts it, the bill stops it.
struct RaceBanner: View {
    let race: Race

    var body: some View {
        switch race.phase {
        case .ready:
            VStack(spacing: 10) {
                Text("Speed race").font(.seed(.title2, .bold))
                Text("Tap GO with the video, then Ring up").foregroundStyle(Brand.muted)
                HStack(spacing: 16) {
                    Button("Cancel", role: .cancel) { race.reset() }
                    Button { race.go() } label: {
                        Text("GO").font(.seed(.title, .bold)).frame(minWidth: 120)
                    }
                    .primaryButton()
                    .controlSize(.extraLarge)
                }
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        case .running:
            RaceClock(start: race.startedAt)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        case .done:
            VStack(spacing: 4) {
                Text(String(format: "%.1f s", race.time?.inSeconds ?? 0))
                    .font(.seed(size: 72, .extraBold))
                    .foregroundStyle(Brand.accent)
                if let perItem = race.secondsPerItem {
                    Text("^[\(race.items) item](inflect: true) · \(String(format: "%.2f", perItem)) s an item")
                        .font(.seed(.title3, .bold))
                }
                Button("Close") { race.reset() }.padding(.top, 6)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        case .idle:
            EmptyView()
        }
    }
}

struct RaceClock: View {
    let start: ContinuousClock.Instant?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            // A fixed width: the face has no tabular digits, so the glass pill wobbled ten times a second.
            Text(String(format: "%.1f s", start.map { (ContinuousClock.now - $0).inSeconds } ?? 0))
                .font(.seed(size: 72, .extraBold))
                .frame(minWidth: 280)
        }
    }
}
