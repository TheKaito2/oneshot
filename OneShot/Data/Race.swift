import Foundation
import Observation

/// Demo beat 1, the stage timer: OneShot rings up live next to a video of a 7-Eleven cashier scanning the same items.
/// GO starts the clock in step with the video; it stops the instant the bill is built. (The iPad's own barcode lap
/// was dropped: the camera spent most of it refocusing, which made the comparison unfair.)
@Observable
final class Race {
    enum Phase: Equatable { case idle, ready, running, done }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var time: Duration?
    private(set) var items = 0

    /// Shows the GO banner over the scan zone.
    func start() {
        startedAt = nil
        time = nil
        items = 0
        phase = .ready
    }

    func go(at now: ContinuousClock.Instant = .now) {
        guard phase == .ready else { return }
        startedAt = now
        phase = .running
    }

    /// Stops the clock when the bill is built.
    func billShown(items: Int, at now: ContinuousClock.Instant = .now) {
        guard phase == .running, let startedAt else { return }
        time = now - startedAt
        self.items = items
        phase = .done
    }

    func reset() { phase = .idle }

    var secondsPerItem: Double? {
        guard let time, items > 0 else { return nil }
        return time.inSeconds / Double(items)
    }

    var summary: String? {
        guard let time, let perItem = secondsPerItem else { return nil }
        return String(AttributedString(localized: "^[\(items) item](inflect: true) in \(String(format: "%.1f", time.inSeconds)) s · \(String(format: "%.2f", perItem)) s an item").characters)
    }
}

extension Duration {
    var inSeconds: Double { self / .seconds(1) }
}
