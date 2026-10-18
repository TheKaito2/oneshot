import Observation

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
    /// The Teach-a-product panel is open in Checkout.
    var teaching = false
    /// Shelf counts; sales take from it, refunds and deliveries add to it.
    var stock: StockBook

    let camera = CameraController()
    let gallery = Gallery()
    let race = Race()

    /// The camera rests whenever nothing needs it live: another tab or a frozen sale (unless scanning more into it).
    var cameraIdle: Bool { tab != .checkout || (scan != nil && !scanningMore) }

    /// Picks up barcodes, prices and quick-adds saved since launch.
    func reloadCatalog() { catalog = Catalog.load() }

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

    func startTeaching() {
        scan = nil
        teaching = true
        tab = .checkout
    }
}
