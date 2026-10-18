import Testing
@testable import OneShot

struct RaceTests {
    @Test func goToBillIsTimedWithSecondsPerItem() {
        let race = Race()
        let t0 = ContinuousClock.now
        race.start()
        #expect(race.phase == .ready)
        race.go(at: t0)
        #expect(race.phase == .running)
        race.billShown(items: 4, at: t0.advanced(by: .seconds(1.5)))
        #expect(race.phase == .done)
        #expect(race.time == .seconds(1.5))
        #expect(race.secondsPerItem == 0.375)
        #expect(race.summary == "4 items in 1.5 s · 0.38 s an item")
    }

    @Test func billWithoutGoIsNotTimed() {
        let race = Race()
        race.start()
        race.billShown(items: 3)
        #expect(race.phase == .ready)
        #expect(race.summary == nil)
    }

    @Test func restartClearsTheLastResult() {
        let race = Race()
        let t0 = ContinuousClock.now
        race.start()
        race.go(at: t0)
        race.billShown(items: 2, at: t0.advanced(by: .seconds(1)))
        race.start()
        #expect(race.phase == .ready)
        #expect(race.time == nil)
        #expect(race.summary == nil)
    }

    @Test func emptyBillGivesNoPace() {
        let race = Race()
        let t0 = ContinuousClock.now
        race.start()
        race.go(at: t0)
        race.billShown(items: 0, at: t0.advanced(by: .seconds(1)))
        #expect(race.secondsPerItem == nil)
        #expect(race.summary == nil)
    }
}
