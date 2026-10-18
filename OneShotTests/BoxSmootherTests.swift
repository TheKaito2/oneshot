import CoreGraphics
import Testing
@testable import OneShot

struct BoxSmootherTests {
    private func box(_ label: String, x: CGFloat = 0.1, y: CGFloat = 0.1) -> Box {
        Box(rect: CGRect(x: x, y: y, width: 0.2, height: 0.2), guesses: [Guess(label: label, confidence: 0.9)])
    }

    /// Feeds the same detections `times` times and returns what the last one shows.
    private func feed(_ smoother: inout BoxSmoother, _ boxes: [Box], times: Int) -> [Box] {
        var shown: [Box] = []
        for _ in 0..<times { shown = smoother.update(boxes) }
        return shown
    }

    private let n = BoxSmoother().confirm

    @Test func showsOnlyAfterConfirmDetectionsInARow() {
        var smoother = BoxSmoother()
        #expect(feed(&smoother, [box("lays")], times: n - 1).isEmpty)
        #expect(smoother.update([box("lays")]).map(\.label) == ["lays"])
    }

    @Test func aMissBeforeShowingRestartsTheCount() {
        var smoother = BoxSmoother()
        _ = feed(&smoother, [box("lays")], times: n - 1)
        _ = smoother.update([])
        #expect(feed(&smoother, [box("lays")], times: n - 1).isEmpty)
        #expect(smoother.update([box("lays")]).count == 1)
    }

    @Test func staysThroughMissesUntilConfirmInARow() {
        var smoother = BoxSmoother()
        _ = feed(&smoother, [box("lays")], times: n)
        #expect(feed(&smoother, [], times: n - 1).count == 1)
        #expect(smoother.update([]).isEmpty)
    }

    @Test func labelChangesOnlyWhenTheNewLabelHolds() {
        var smoother = BoxSmoother()
        _ = feed(&smoother, [box("lays")], times: n)
        // Flicker: "mars" one short of the count, then "lays" again, resets it.
        _ = feed(&smoother, [box("mars")], times: n - 1)
        #expect(smoother.update([box("lays")]).map(\.label) == ["lays"])
        #expect(feed(&smoother, [box("mars")], times: n - 1).map(\.label) == ["lays"])
        #expect(smoother.update([box("mars")]).map(\.label) == ["mars"])
    }

    @Test func jitterNeverMovesTheBoxButARealMoveDoes() {
        var smoother = BoxSmoother()
        let start = feed(&smoother, [box("lays")], times: n)
        // 0.02 shift: overlap 0.82, jitter. The shown box stays put exactly.
        #expect(feed(&smoother, [box("lays", x: 0.12)], times: 10).map(\.rect) == start.map(\.rect))
        // 0.08 shift: overlap 0.43, a move. Shown once it holds `n` in a row.
        #expect(feed(&smoother, [box("lays", x: 0.18)], times: n - 1).map(\.rect) == start.map(\.rect))
        #expect(smoother.update([box("lays", x: 0.18)]).first?.rect.minX == 0.18)
    }

    @Test func twoItemsAreTrackedApart() {
        var smoother = BoxSmoother()
        let shown = feed(&smoother, [box("lays"), box("mars", x: 0.6, y: 0.6)], times: n)
        #expect(Set(shown.map(\.label)) == ["lays", "mars"])
    }
}
