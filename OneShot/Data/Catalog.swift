import Foundation

struct Product: Codable, Identifiable, Hashable {
    /// Same string as the detector's class label.
    let id: String
    let nameEN: String
    let nameTH: String
    /// Baht.
    var price: Decimal
    let barcode: String?
    /// Shelf group for Reports › Sales by category; nil (quick-adds, older catalogs) reads as Other.
    var category: ProductCategory?
    /// What the shop pays per unit, typed in Products (`costs.json`). nil = unknown, so no profit is claimed for it.
    var cost: Decimal?
    /// Pack size ("S", "M") where one product comes in look-alike sizes, drawn as a badge on its photo; nil otherwise.
    var size: String?

    /// Follows the app's language (iOS Settings › OneShot › Language).
    var name: String { Bundle.main.preferredLocalizations.first == "th" ? nameTH : nameEN }
}

/// Shelf groups, as Loyverse and Square report sales by category.
enum ProductCategory: String, Codable, CaseIterable {
    case chips, chocolate, biscuits, candy, drinks, other

    var title: LocalizedStringResource {
        switch self {
        case .chips: "Chips"
        case .chocolate: "Chocolate"
        case .biscuits: "Biscuits"
        case .candy: "Candy"
        case .drinks: "Drinks"
        case .other: "Other"
        }
    }
}

struct Catalog {
    let products: [Product]
    /// Barcode → SKU, scanned once inside the app (`barcodes.json`); wins over `Product.barcode`.
    private let assigned: [String: String]
    private let byID: [String: Product]

    init(products: [Product], assigned: [String: String] = [:]) {
        self.products = products
        self.assigned = assigned
        byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(id: String) -> Product? { byID[id] }

    func product(barcode: String) -> Product? {
        if let sku = assigned[barcode] { return byID[sku] }
        return products.first { $0.barcode == barcode }
    }

    func adding(_ product: Product) -> Catalog { Catalog(products: products + [product], assigned: assigned) }

    private static let quickAddURL = URL.documentsDirectory.appending(path: "quickadd.json")
    private static let barcodesURL = URL.documentsDirectory.appending(path: "barcodes.json")
    private static let pricesURL = URL.documentsDirectory.appending(path: "prices.json")
    private static let costsURL = URL.documentsDirectory.appending(path: "costs.json")

    /// Bundled products plus the ones quick-added on this iPad, with in-app barcode assignments, price edits and costs.
    static func load() -> Catalog {
        let prices = read([String: Decimal].self, from: pricesURL) ?? [:]
        let costs = read([String: Decimal].self, from: costsURL) ?? [:]
        let products = (bundled() + quickAdded()).map { product in
            var product = product
            if let price = prices[product.id] { product.price = price }
            product.cost = costs[product.id]
            return product
        }
        return Catalog(products: products, assigned: read([String: String].self, from: barcodesURL) ?? [:])
    }

    /// A shop changes a price on the iPad; it wins over catalog.json and the quick-add price.
    static func savePrice(_ price: Decimal, for sku: String) throws {
        var all = read([String: Decimal].self, from: pricesURL) ?? [:]
        all[sku] = price
        try JSONEncoder().encode(all).write(to: pricesURL, options: .atomic)
    }

    /// The shop's cost per unit, for profit in Reports; nil forgets it.
    static func saveCost(_ cost: Decimal?, for sku: String) throws {
        var all = read([String: Decimal].self, from: costsURL) ?? [:]
        all[sku] = cost
        try JSONEncoder().encode(all).write(to: costsURL, options: .atomic)
    }

    /// Barcodes remembered for `sku` in the app.
    func barcodes(for sku: String) -> [String] {
        assigned.filter { $0.value == sku }.map(\.key).sorted() + (byID[sku]?.barcode.map { [$0] } ?? [])
    }

    /// Persists a quick-added product so it survives relaunch.
    static func saveQuickAdd(_ product: Product) throws {
        try JSONEncoder().encode(quickAdded() + [product]).write(to: quickAddURL, options: .atomic)
    }

    /// Taught products have ids starting "qa-"; only these can be deleted (the bundled ones ship with the model).
    static func isQuickAdd(_ sku: String) -> Bool { sku.hasPrefix("qa-") }

    /// Deletes a taught product: a rehearsal or duplicate teach used to stay forever and keep voting.
    static func removeQuickAdd(_ sku: String) throws {
        try JSONEncoder().encode(quickAdded().filter { $0.id != sku }).write(to: quickAddURL, options: .atomic)
        let photos = URL.documentsDirectory.appending(path: "Crops/\(sku)", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: photos.path()) { try FileManager.default.removeItem(at: photos) }
    }

    /// Remembers that `code` is `sku`; the catalog sheet needs no barcodes typed in.
    static func assignBarcode(_ code: String, to sku: String) throws {
        var all = read([String: String].self, from: barcodesURL) ?? [:]
        all[code] = sku
        try JSONEncoder().encode(all).write(to: barcodesURL, options: .atomic)
    }

    /// `catalog.json` ships inside the app, so a decode failure is a build bug: fail loudly.
    private static func bundled() -> [Product] {
        do {
            guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
                fatalError("catalog.json is missing from the app bundle")
            }
            return try JSONDecoder().decode([Product].self, from: Data(contentsOf: url))
        } catch {
            fatalError("catalog.json: \(error)")
        }
    }

    private static func quickAdded() -> [Product] {
        read([Product].self, from: quickAddURL) ?? []
    }

    /// nil when the file doesn't exist yet; an unreadable file is logged, not silently treated as empty.
    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            print("\(url.lastPathComponent) unreadable: \(error)")
            return nil
        }
    }
}

extension Decimal {
    /// A typed amount: "25", "59.90", "1,250", "฿1,250.5". Nil for anything else, including more than 2 decimals.
    /// `Decimal(string:)` stopped at the first comma, so "1,250" saved as ฿1 (19 Oct).
    init?(baht text: String) {
        let cleaned = text.filter { !$0.isWhitespace && $0 != "," && $0 != "฿" }
        guard cleaned.wholeMatch(of: /\d+(\.\d{1,2})?/) != nil, let value = Decimal(string: cleaned) else { return nil }
        self = value
    }

    /// "฿25" or "฿59.90", the way Thai shops write prices.
    var baht: String {
        var whole = Decimal(), value = self
        NSDecimalRound(&whole, &value, 0, .plain)
        let digits = whole == self ? 0 : 2
        let amount = (self < 0 ? -self : self).formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
        return (self < 0 ? "−฿" : "฿") + amount
    }
}
