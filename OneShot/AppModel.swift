import Observation
import TipKit

/// State the tabs share: one camera, one catalog, one gallery, the race, and the sale in progress.
@Observable
final class AppModel {
    enum Tab: Hashable { case home, checkout, products, reports, settings }

    var tab: Tab = .home
    var catalog = Catalog.load()
    /// The sale on the counter: one locked frame and its regions. nil = the scan zone is live.
    var scan: LockedScan? {
        didSet { if scan == nil { scanningMore = false } }
    }
    /// Add items › Scan more: the bill stays, the camera comes back, and the next Ring up adds to it.
    var scanningMore = false
    /// Demo camera: bundled table photos stand in for the live feed (DemoFeed). On by default in the simulator,
    /// which has no camera, so the app can be presented from a Mac.
    var demo: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()
    /// Which demo photo is in the zone; Next photo and Scan more step through them.
    var demoIndex = 0
    /// The Teach-a-product panel is open in Checkout.
    var teaching = false
    /// Shelf counts; sales take from it, refunds and deliveries add to it.
    var stock: StockBook

    let camera = CameraController()
    let gallery = Gallery()
    let race = Race()

    /// The camera rests whenever nothing needs it live: another tab or a frozen sale (unless scanning more into it,
    /// or teaching a product the bill is waiting on).
    var cameraIdle: Bool { tab != .checkout || (demo && !teaching) || (scan != nil && !scanningMore && !teaching) }

    /// Picks up barcodes, prices and quick-adds saved since launch. A product that's gone (a deleted teach) can't stay
    /// billed at its old price: its boxes turn yellow again and its hand-added units go, so Charge waits for a pick.
    func reloadCatalog() {
        catalog = Catalog.load()
        guard var open = scan else { return }
        open.manual.removeAll { catalog[$0] == nil }
        for index in open.regions.indices {
            if let sku = open.regions[index].verdict.sku, catalog[sku] == nil {
                open.regions[index].verdict = .unsure(candidates: [])
            }
        }
        scan = open
    }

    @MainActor
    init() { stock = StockBook.load(from: Store.context) }

    @MainActor
    func applyToStock(_ sale: Sale) {
        stock.apply(sale)
        saveStock()
    }

    @MainActor
    func saveStock() {
        do {
            try stock.save(to: Store.context)
        } catch {
            print("stock not saved: \(error)")
        }
    }

    /// Opens Teach a product. An open bill stays: teach the unknown pack, then pick it on the bill (it used to be
    /// wiped without a word).
    func startTeaching() {
        QuickAddTip().invalidate(reason: .actionPerformed)
        scanningMore = false
        teaching = true
        tab = .checkout
    }

    /// Back to a live scan zone for the next customer: Start over, New sale and the speed race all come here.
    func clearSale() {
        scan = nil
        reloadCatalog()   // barcodes assigned in the pick list
        if race.phase == .done { race.reset() }
    }

    /// The speed race starts on an empty counter, or Ring up would be blocked while the clock runs.
    func startRace() {
        guard scan == nil, !teaching else { return }   // callers disable it then; never wipe a sale for a race
        clearSale()
        race.start()
        tab = .checkout
    }
}
