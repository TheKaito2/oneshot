import XCTest

/// A walk through every page in portrait and landscape, as a judge would see it, with a screenshot of each.
/// Runs on the simulator with the demo camera (on there by default). Run with the OneShotTour scheme; set
/// TEST_RUNNER_TOUR_LANG=th for Thai. Screenshots are attachments in the .xcresult
/// (`xcrun xcresulttool export attachments`).
final class TourTests: XCTestCase {
    private var app: XCUIApplication!
    private var thai = false

    /// The labels the tour taps, in the app's language.
    private func label(_ english: String) -> String {
        guard thai else { return english }
        return [
            "Home": "หน้าหลัก", "Checkout": "ขายของ", "Products": "สินค้า", "Reports": "รายงาน", "Settings": "ตั้งค่า",
            "Scan the items in view": "สแกนสินค้าที่อยู่ในภาพ", "Back": "กลับ", "Charge": "เก็บเงิน",
            "Add two weeks of sample sales": "เพิ่มยอดขายตัวอย่าง 2 สัปดาห์", "Add sample sales": "เพิ่มยอดขายตัวอย่าง",
            "This month": "เดือนนี้", "Add items": "เพิ่มสินค้า", "Scan more items": "สแกนเพิ่ม",
            "Start over": "เริ่มใหม่", "Done": "เสร็จ", "Demo & sample data": "เดโมและข้อมูลตัวอย่าง", "Scanner": "สแกน", "Cart": "ตะกร้า", "Add item": "เพิ่มสินค้า", "Scan with OneShot": "สแกนด้วย OneShot", "Cancel": "ยกเลิก", "Show all": "ดูทั้งหมด",
        ][english] ?? english
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        thai = ProcessInfo.processInfo.environment["TOUR_LANG"] == "th"
        app = XCUIApplication()
        app.launchArguments += thai ? ["-AppleLanguages", "(th)", "-AppleLocale", "th_TH"]
                                    : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-promptPayID", "0812345678", "-onboarded", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        dismissCameraPrompt()
    }

    /// First launch: every onboarding page, then the shop it set up (iPhone and iPad, 22 Oct).
    func testOnboarding() throws {
        app.terminate()
        app.launchArguments = app.launchArguments.map { $0 == "YES" ? "NO" : $0 }   // -onboarded NO
        app.launch()
        let start = button("Get started")
        XCTAssertTrue(start.waitForExistence(timeout: 15), "onboarding didn't show")
        shot("portrait-16-onboarding-welcome")
        start.tap()
        if !button("Allow the camera").waitForExistence(timeout: 3), start.exists { start.tap() }   // swallowed on a busy Mac
        shot("portrait-17-onboarding-camera")
        button("Skip").tap()
        let name = app.textFields["Shop name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Somchai Shop")
        shot("portrait-18-onboarding-shop")
        button("Continue").tap()
        let id = app.textFields["Mobile, 13-digit ID or e-wallet"]
        XCTAssertTrue(id.waitForExistence(timeout: 5))
        shot("portrait-19-onboarding-promptpay")
        button("Continue").tap()   // keeps the -promptPayID launch value
        XCTAssertTrue(app.secureTextFields["4-digit PIN"].waitForExistence(timeout: 5))
        shot("portrait-20-onboarding-pin")
        button("Skip").tap()
        let samples = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Try it with 12 sample snacks")).firstMatch
        XCTAssertTrue(samples.waitForExistence(timeout: 5))
        shot("portrait-21-onboarding-products")
        samples.tap()
        if samples.waitForExistence(timeout: 5), samples.isHittable { samples.tap() }   // swallowed on a busy Mac
        if button("Not now").waitForExistence(timeout: 3) {   // only in a build with accounts
            shot("portrait-22-onboarding-account")
            button("Not now").tap()
        }
        XCTAssertTrue(button("Home").waitForExistence(timeout: 10) || app.cells["Home"].exists, "onboarding didn't finish")
        go("Products")
        XCTAssertTrue(app.staticTexts["KitKat"].waitForExistence(timeout: 5), "sample snacks weren't added")
        shot("portrait-23-after-onboarding-products")
    }

    /// The Teach panel in Checkout: header, scrolling middle and action button all reachable (iPhone, 20 Oct).
    func testTeachPanel() throws {
        go("Checkout")
        let teach = button("Teach")
        XCTAssertTrue(teach.waitForExistence(timeout: 10), "Teach missing")
        teach.tap()
        let cancel = button("Cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Teach panel didn't open")
        XCTAssertTrue(cancel.isHittable, "Cancel is off screen")
        XCTAssertTrue(button("Take photo").isHittable, "Take photo is off screen")
        shot("portrait-14-teach")
        app.staticTexts["Put the item on its own with a gap around it. Turn it a little between shots."].swipeUp()
        sleep(1)
        shot("portrait-15-teach-scrolled")
        cancel.tap()
    }

    func testTour() throws {
        addSampleSalesIfOffered()
        // iPhone is portrait only.
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            sleep(3)
            let frame = app.windows.firstMatch.frame
            XCTAssertEqual(frame.width > frame.height, orientation.isLandscape, "the simulator didn't rotate to \(orientation.rawValue)")
            let o = orientation == .portrait ? "portrait" : "landscape"
            go("Home")
            shot("\(o)-01-home")
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            shot("\(o)-02-home-lower")

            go("Checkout")
            sleep(3)   // demo photo and its boxes
            shot("\(o)-03-checkout-live")
            if UIDevice.current.userInterfaceIdiom == .phone {
                // iPhone: the cart is the page beside the scanner, off screen until Ring up.
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label("Charge"))).firstMatch.isHittable,
                               "the empty cart shows before Ring up")
            }
            let ringUp = button(label("Scan the items in view"))
            XCTAssertTrue(ringUp.waitForExistence(timeout: 5), "Ring up missing")
            ringUp.tap()
            // The bill's own buttons mean it's built; detection runs on the simulator's CPU, slow on a busy Mac.
            let addItems = button(label("Add items"))
            XCTAssertTrue(addItems.waitForExistence(timeout: 30), "no bill after Ring up")
            sleep(1)
            shot("\(o)-04-checkout-bill")
            showPage("Scanner")   // stacked layouts page between the scanner and the cart
            do {
                addItems.tap()
                let scanMore = button(label("Scan more items"))
                // On a loaded Mac the first tap can land before the menu is ready.
                if !scanMore.waitForExistence(timeout: 3) { addItems.tap() }
                XCTAssertTrue(scanMore.waitForExistence(timeout: 5), "Add items menu didn't open")
                shot("\(o)-05-add-items-menu")
                scanMore.tap()
                sleep(3)
                shot("\(o)-06-scan-more")
                ringUp.tap()
                if !addItems.waitForExistence(timeout: 15), ringUp.isEnabled { ringUp.tap() }   // swallowed, like the tabs
                XCTAssertTrue(addItems.waitForExistence(timeout: 30), "no merged bill after the second Ring up")
                sleep(1)
                shot("\(o)-07-bill-merged")
                showPage("Cart")
                // Add item's options: OneShot first, then barcode, then the list.
                let addItem = visible(label("Add item"))
                if addItem.exists, addItem.isHittable {
                    addItem.tap()
                    if app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label("Scan with OneShot"))).firstMatch.waitForExistence(timeout: 5) {
                        shot("\(o)-24-add-item-options")
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()   // above the sheet: closes it
                        sleep(1)
                    }
                }
            }
            let charge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label("Charge"))).firstMatch
            if charge.waitForExistence(timeout: 3), charge.isEnabled {
                charge.tap()
                let back = button(label("Back"))
                if !back.waitForExistence(timeout: 10) { charge.tap() }   // swallowed on a busy Mac, like the tabs
                XCTAssertTrue(back.waitForExistence(timeout: 10), "Pay didn't open")
                sleep(1)
                shot("\(o)-08-pay")
                back.tap()
                sleep(1)
            } else {
                shot("\(o)-08-charge-disabled")
            }
            visible(label("Start over")).tap()
            sleep(1)

            go("Products")
            shot("\(o)-09-products")
            if orientation == .portrait {
                let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hershey")).firstMatch
                if first.waitForExistence(timeout: 3) {
                    first.tap()
                    if button(label("Cancel")).waitForExistence(timeout: 5) {
                        sleep(1)
                        shot("\(o)-25-product-detail")
                        button(label("Cancel")).tap()
                        sleep(1)
                    }
                }
            }
            go("Reports")
            shot("\(o)-10-reports")
            if orientation == .portrait {
                // A chart card opened full screen (⤢).
                let expand = app.buttons.matching(NSPredicate(format: "label == %@", label("Show all"))).firstMatch
                if expand.waitForExistence(timeout: 3), expand.isHittable {
                    expand.tap()
                    if button(label("Done")).waitForExistence(timeout: 5) {
                        sleep(1)
                        shot("\(o)-26-chart-detail")
                        button(label("Done")).tap()
                        sleep(1)
                    }
                }
            }
            let month = button(label("This month"))
            if month.exists { month.tap() }
            app.swipeUp(velocity: .fast)
            shot("\(o)-11-reports-month")
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            shot("\(o)-12-reports-lower")

            if orientation == .landscapeLeft {
                // Checkout with the sidebar docked: the narrowest landscape layout.
                go("Checkout")
                // Landscape opens with the sidebar docked; this is Checkout with it hidden, the full-width layout.
                let toggle = app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'sidebar' OR label CONTAINS[c] 'sidebar'")).firstMatch
                if toggle.waitForExistence(timeout: 2) {
                    toggle.tap()
                    sleep(2)
                    shot("\(o)-14-checkout-no-sidebar")
                    // The full-width layout with a bill on it (the thumbnail and store screenshots use this one).
                    let ringUp = button(label("Scan the items in view"))
                    if ringUp.waitForExistence(timeout: 5), ringUp.isEnabled {
                        ringUp.tap()
                        if button(label("Add items")).waitForExistence(timeout: 30) {
                            sleep(1)
                            shot("\(o)-15-checkout-bill-no-sidebar")
                        }
                        button(label("Start over")).tap()
                        sleep(1)
                    }
                    if toggle.exists, toggle.isHittable { toggle.tap() }
                    sleep(1)
                } else {
                    print("no sidebar toggle found")
                }
            }
            openSettings()
            shot("\(o)-13-settings")
            if orientation == .portrait {
                row("Shop details").tap()
                sleep(1)
                shot("\(o)-16-settings-shop")
                backInSettings()
            }
            closeSheet()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Helpers

    /// A tab by name, from the tab bar (or the sidebar in landscape).
    private func go(_ tab: String) {
        let name = label(tab)
        // Tab bar items are buttons; landscape's docked sidebar shows them as cells or text.
        let candidates = [button(name),
                          app.cells.matching(NSPredicate(format: "label == %@", name)).firstMatch,
                          app.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch]
        _ = candidates[0].waitForExistence(timeout: 3)
        guard let target = candidates.first(where: { $0.exists && $0.isHittable }) else {
            return XCTFail("no way to \(tab)")
        }
        target.tap()
        sleep(2)
        // A tap during the previous page's scroll momentum is swallowed (seen on a loaded Mac, 20 Oct): once more.
        if target.exists, target.isHittable, !target.isSelected {
            target.tap()
            sleep(2)
        }
    }

    /// Settings is a sheet from Home's gear.
    private func openSettings() {
        go("Home")
        app.swipeDown(velocity: .fast)
        button(label("Settings")).tap()
        sleep(2)
    }

    /// A button by its visible label (subscripts match identifiers only, and the tab bar's are SF Symbol names).
    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func shot(_ name: String) {
        // The screenshot's PNG is the raw portrait buffer; its UIImage carries the orientation, so draw that upright.
        let image = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        print("shot \(name) size=\(image.size) orientation=\(image.imageOrientation.rawValue)")
        let attachment = XCTAttachment(image: upright)
        attachment.name = (thai ? "th-" : "") + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissCameraPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "อนุญาต"] where springboard.buttons[title].waitForExistence(timeout: 3) {
            springboard.buttons[title].tap()
            return
        }
    }

    /// Stacked Checkout: the Scanner / Cart switch, when there is one.
    private func showPage(_ name: String) {
        let segment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label(name))).firstMatch   // "Cart (12)"
        if segment.exists, segment.isHittable {
            segment.tap()
            sleep(1)
        }
    }

    /// The on-screen one of several same-named buttons (the zone's and the cart's Start over).
    private func visible(_ label: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", label))
        return (0..<all.count).map { all.element(boundBy: $0) }.first { $0.isHittable } ?? all.firstMatch
    }

    /// A Settings row (a navigation link reads its title, then its value).
    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label(title))).firstMatch
    }

    private func backInSettings() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    private func addSampleSalesIfOffered() {
        openSettings()
        row("Demo & sample data").tap()
        sleep(1)
        let add = button(label("Add two weeks of sample sales"))
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        if add.exists, add.isEnabled {
            add.tap()
            let confirm = button(label("Add sample sales"))
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            sleep(2)
            XCTAssertFalse(add.isEnabled, "sample sales weren't added")
        }
        backInSettings()
        closeSheet()
    }

    /// Done until the sheet is really gone (the first tap can land on a popover still showing over it).
    private func closeSheet() {
        let done = button(label("Done"))
        for _ in 0..<3 where done.exists {
            done.tap()
            sleep(1)
        }
        XCTAssertFalse(done.exists, "the sheet didn't close")
    }
}
