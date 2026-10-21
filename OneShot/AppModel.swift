import Observation
import TipKit

/// State the tabs share: one camera, one catalog, one gallery, and the sale in progress.
@Observable
final class AppModel {
    enum Tab: Hashable { case home, checkout, products, reports }

    var tab: Tab = .home
    /// Settings, as a sheet over whatever tab is showing.
    var showingSettings = false
    var catalog: Catalog
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

    /// The camera rests whenever nothing needs it live: another tab or a frozen sale (unless scanning more into it,
    /// or teaching a product the bill is waiting on).
    var cameraIdle: Bool { tab != .checkout || (demo && !teaching) || (scan != nil && !scanningMore && !teaching) }

    /// Picks up barcodes, prices and quick-adds saved since launch. A product that's gone (a deleted teach) can't stay
    /// billed at its old price: its boxes turn yellow again and its hand-added units go, so Charge waits for a pick.
    @MainActor
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
    init() {
        catalog = Catalog.load()
        stock = StockBook.load(from: Store.context)
    }

    /// The 12 sample snacks, for Demo and onboarding; missing ones only.
    @MainActor
    func addSampleProducts() {
        do {
            try Catalog.addSamples()
            reloadCatalog()
        } catch {
            Log.error("samples not added: \(error)")
        }
    }

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
            Log.error("stock not saved: \(error)")
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

    /// Back to a live scan zone for the next customer: Start over and New sale both come here.
    @MainActor
    func clearSale() {
        scan = nil
        reloadCatalog()   // barcodes assigned in the pick list
    }
}
