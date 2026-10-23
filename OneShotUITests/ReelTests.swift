import XCTest

/// Drives the hero moments for the demo-video intro at a filmable pace, while `simctl io recordVideo` records the
/// screen (23 Oct). Not a check: every step only waits for the thing the camera needs. Run one method at a time:
/// `-only-testing:OneShotUITests/ReelTests/testReelPad` on the iPad, `testReelPhone` on the iPhone.
final class ReelTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-promptPayID", "0812345678", "-onboarded", "YES"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
    }

    /// iPad, landscape: live boxes, Scan, the bill, the PromptPay QR, Paid; twice so Home has today's numbers.
    func testReelPad() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        // The top tab bar films better than the sidebar; iPadOS restores a sidebar left open.
        let hide = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Hide Sidebar")).firstMatch
        if hide.exists, hide.isHittable { hide.tap(); sleep(1) }
        for _ in 0..<2 { sale() }
        go("Products"); sleep(3)
        app.swipeUp(velocity: .slow); sleep(2)
        go("Reports"); sleep(3)
        app.swipeUp(velocity: .slow); sleep(2)
        go("Home"); sleep(4)
    }

    /// iPhone, portrait: the Scan circle, the cart sliding in, a swipe back to the photo, Reports with a chart opened.
    func testReelPhone() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        go("Home"); sleep(2)
        button("Checkout").tap(); sleep(4)
        scan()
        sleep(3)
        app.swipeRight(); sleep(3)   // back to the scanner page
        app.swipeLeft(); sleep(3)    // and the cart again
        go("Reports"); sleep(3)
        let expand = button("Show all")
        if expand.waitForExistence(timeout: 3) { expand.tap() }
        sleep(2)
        // Scrub the opened trend chart left to right.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4))
            .press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4)))
        sleep(3)
    }

    // MARK: - Steps

    private func sale() {
        go("Checkout"); sleep(4)   // live boxes on the demo photo
        scan()
        sleep(3)                   // hold the finished bill
        let charge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Charge")).firstMatch
        charge.tap()
        let paid = button("Paid")
        if !paid.waitForExistence(timeout: 10) { charge.tap() }
        sleep(5)                   // the QR and the spoken total
        paid.tap(); sleep(3)
        let next = button("New sale")
        if next.waitForExistence(timeout: 5) { next.tap() }
        sleep(2)
    }

    private func scan() {
        let scan = button("Scan the items in view")
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        let addItems = button("Add items")
        if !addItems.waitForExistence(timeout: 15), scan.isEnabled { scan.tap() }
        XCTAssertTrue(addItems.waitForExistence(timeout: 30), "no bill after Scan")
    }

    private func go(_ tab: String) {
        let candidates = [button(tab),
                          app.cells.matching(NSPredicate(format: "label == %@", tab)).firstMatch,
                          app.staticTexts.matching(NSPredicate(format: "label == %@", tab)).firstMatch]
        _ = candidates[0].waitForExistence(timeout: 5)
        guard let target = candidates.first(where: { $0.exists && $0.isHittable }) else { return XCTFail("no \(tab)") }
        target.tap()
        sleep(2)
        if target.exists, target.isHittable, !target.isSelected { target.tap(); sleep(1) }   // swallowed on a busy Mac
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
