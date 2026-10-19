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
            "Ring up the items in view": "คิดเงินสินค้าที่อยู่ในภาพ", "Back": "กลับ", "Charge": "เก็บเงิน",
            "Add two weeks of sample sales": "เพิ่มยอดขายตัวอย่าง 2 สัปดาห์", "Add sample sales": "เพิ่มยอดขายตัวอย่าง",
            "This month": "เดือนนี้", "Add items": "เพิ่มสินค้า", "Scan more items": "สแกนเพิ่ม",
            "Start over": "เริ่มใหม่", "Done": "เสร็จ",
        ][english] ?? english
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        thai = ProcessInfo.processInfo.environment["TOUR_LANG"] == "th"
        app = XCUIApplication()
        app.launchArguments += thai ? ["-AppleLanguages", "(th)", "-AppleLocale", "th_TH"]
                                    : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-promptPayID", "0812345678"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        dismissCameraPrompt()
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
            let ringUp = button(label("Ring up the items in view"))
            XCTAssertTrue(ringUp.waitForExistence(timeout: 5), "Ring up missing")
            ringUp.tap()
            // The bill's own buttons mean it's built; detection runs on the simulator's CPU, slow on a busy Mac.
            let addItems = button(label("Add items"))
            XCTAssertTrue(addItems.waitForExistence(timeout: 30), "no bill after Ring up")
            sleep(1)
            shot("\(o)-04-checkout-bill")
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
                XCTAssertTrue(addItems.waitForExistence(timeout: 30), "no merged bill after the second Ring up")
                sleep(1)
                shot("\(o)-07-bill-merged")
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
            button(label("Start over")).tap()
            sleep(1)

            go("Products")
            shot("\(o)-09-products")
            go("Reports")
            shot("\(o)-10-reports")
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
                    if toggle.exists, toggle.isHittable { toggle.tap() }
                    sleep(1)
                } else {
                    print("no sidebar toggle found")
                }
            }
            openSettings()
            shot("\(o)-13-settings")
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
        if candidates[0].exists, !candidates[0].isSelected {
            candidates[0].tap()
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

    private func addSampleSalesIfOffered() {
        openSettings()
        let add = button(label("Add two weeks of sample sales"))
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        if add.exists, add.isEnabled {
            add.tap()
            let confirm = button(label("Add sample sales"))
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            sleep(2)
            XCTAssertFalse(add.isEnabled, "sample sales weren't added")
        }
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
