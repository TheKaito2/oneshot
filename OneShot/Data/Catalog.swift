import Foundation
import SwiftData

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

    /// The shop's products from the store (`ProductRecord`), with barcodes scanned in the app. Taught products last.
    @MainActor
    static func load(from context: ModelContext = Store.context) -> Catalog {
        do {
            let products = try context.fetch(FetchDescriptor<ProductRecord>()).map(\.product)
                .sorted { (isQuickAdd($0.id) ? 1 : 0, $0.nameEN) < (isQuickAdd($1.id) ? 1 : 0, $1.nameEN) }
            let barcodes = try context.fetch(FetchDescriptor<BarcodeRecord>())
            return Catalog(products: products,
                           assigned: Dictionary(barcodes.map { ($0.code, $0.sku) }, uniquingKeysWith: { _, last in last }))
        } catch {
            Log.error("catalog not read: \(error)")
            return Catalog(products: [])
        }
    }

    /// A shop changes a price; it wins over the catalog's and the teach's.
    @MainActor
    static func savePrice(_ price: Decimal, for sku: String, in context: ModelContext = Store.context) throws {
        try update(sku, in: context) { $0.price = price }
    }

    /// The shop's cost per unit, for profit in Reports; nil forgets it.
    @MainActor
    static func saveCost(_ cost: Decimal?, for sku: String, in context: ModelContext = Store.context) throws {
        try update(sku, in: context) { $0.cost = cost }
    }

    /// Barcodes remembered for `sku` in the app.
    func barcodes(for sku: String) -> [String] {
        assigned.filter { $0.value == sku }.map(\.key).sorted() + (byID[sku]?.barcode.map { [$0] } ?? [])
    }

    /// Stores a taught product.
    @MainActor
    static func saveQuickAdd(_ product: Product, in context: ModelContext = Store.context) throws {
        context.insert(ProductRecord(product))
        try context.save()
    }

    /// Taught products have ids starting "qa-"; only these can be deleted (the bundled ones ship with the model).
    static func isQuickAdd(_ sku: String) -> Bool { sku.hasPrefix("qa-") }

    /// Deletes a taught product: a rehearsal or duplicate teach used to stay forever and keep voting.
    /// Leaves a tombstone so a synced device deletes it too.
    @MainActor
    static func removeQuickAdd(_ sku: String, in context: ModelContext = Store.context) throws {
        for record in try context.fetch(FetchDescriptor<ProductRecord>(predicate: #Predicate { $0.id == sku })) {
            context.delete(record)
        }
        context.insert(TombstoneRecord(kind: "product", key: sku))
        try context.save()
        let photos = URL.documentsDirectory.appending(path: "Crops/\(sku)", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: photos.path()) { try FileManager.default.removeItem(at: photos) }
    }

    /// Remembers that `code` is `sku`; the catalog sheet needs no barcodes typed in.
    @MainActor
    static func assignBarcode(_ code: String, to sku: String, in context: ModelContext = Store.context) throws {
        if let record = try context.fetch(FetchDescriptor<BarcodeRecord>(predicate: #Predicate { $0.code == code })).first {
            record.sku = sku
            record.updatedAt = .now
        } else {
            context.insert(BarcodeRecord(code: code, sku: sku))
        }
        try context.save()
    }

    /// The 12 snacks OneShot's detector knows, for a shop trying it out (onboarding, Demo). Adds only the missing ones.
    @MainActor
    static func addSamples(to context: ModelContext = Store.context) throws {
        let have = Set(try context.fetch(FetchDescriptor<ProductRecord>()).map(\.id))
        for product in bundled() where !have.contains(product.id) { context.insert(ProductRecord(product)) }
        try context.save()
    }

    /// Whether the store has any product yet.
    @MainActor
    static func isEmpty(_ context: ModelContext = Store.context) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<ProductRecord>())) ?? 0) == 0
    }

    /// Builds before V3 kept the catalog in Documents (`quickadd.json`, `prices.json`, `costs.json`, `barcodes.json`)
    /// on top of the bundled snacks. Once, on a store with no products yet: an install that has used OneShot (any of
    /// those files, or any sale) gets them all as products; a fresh install stays empty for onboarding to fill.
    /// The files are renamed `*.imported`, kept for recovery. Also reads a pre-V3 backup folder put back by Restore.
    @MainActor
    static func importLegacy(into context: ModelContext, folder: URL = .documentsDirectory) {
        let names = ["quickadd.json", "prices.json", "costs.json", "barcodes.json"]
        let files = names.map { folder.appending(path: $0) }
        let hasFiles = files.contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        // Used before, without ever writing a catalog file: sold something, saved a PromptPay ID, or taught a product.
        let used = ((try? context.fetchCount(FetchDescriptor<SaleRecord>())) ?? 0) > 0
            || !(UserDefaults.standard.string(forKey: SettingsKey.promptPayID) ?? "").isEmpty
            || FileManager.default.fileExists(atPath: folder.appending(path: "gallery.json").path(percentEncoded: false))
        guard isEmpty(context), hasFiles || (used && folder == .documentsDirectory) else { return }
        let prices = read([String: Decimal].self, from: files[1]) ?? [:]
        let costs = read([String: Decimal].self, from: files[2]) ?? [:]
        for var product in bundled() + (read([Product].self, from: files[0]) ?? []) {
            if let price = prices[product.id] { product.price = price }
            product.cost = costs[product.id]
            context.insert(ProductRecord(product))
        }
        for (code, sku) in read([String: String].self, from: files[3]) ?? [:] { context.insert(BarcodeRecord(code: code, sku: sku)) }
        do {
            try context.save()
            for file in files where FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                let done = file.appendingPathExtension("imported")
                try? FileManager.default.removeItem(at: done)
                try FileManager.default.moveItem(at: file, to: done)
            }
        } catch {
            context.rollback()
            Log.error("catalog not imported: \(error)")
        }
    }

    /// A backup's catalog replaces this device's: `products.json` + `barcodes.json` (V3 backups), or the pre-V3
    /// files (`quickadd.json`, `prices.json`, …) through `importLegacy`. A backup without either leaves the catalog.
    @MainActor
    static func importBackup(from folder: URL, into context: ModelContext) throws {
        let productsFile = folder.appending(path: "products.json")
        let hasV3 = FileManager.default.fileExists(atPath: productsFile.path(percentEncoded: false))
        let hasLegacy = FileManager.default.fileExists(atPath: folder.appending(path: "quickadd.json").path(percentEncoded: false))
        guard hasV3 || hasLegacy else { return }
        try context.delete(model: ProductRecord.self)
        try context.delete(model: BarcodeRecord.self)
        guard hasV3 else {
            importLegacy(into: context, folder: folder)
            return
        }
        guard let products = read([Product].self, from: productsFile) else {
            context.rollback()
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: String(localized: "The backup's products can't be read.")])
        }
        products.forEach { context.insert(ProductRecord($0)) }
        for (code, sku) in read([String: String].self, from: folder.appending(path: "barcodes.json")) ?? [:] {
            context.insert(BarcodeRecord(code: code, sku: sku))
        }
        try context.save()
    }

    @MainActor
    private static func update(_ sku: String, in context: ModelContext, _ change: (ProductRecord) -> Void) throws {
        guard let record = try context.fetch(FetchDescriptor<ProductRecord>(predicate: #Predicate { $0.id == sku })).first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: String(localized: "That product no longer exists.")])
        }
        change(record)
        record.updatedAt = .now
        try context.save()
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

    /// nil when the file doesn't exist yet; an unreadable file is logged, not silently treated as empty.
    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            Log.error("\(url.lastPathComponent) unreadable: \(error)")
            return nil
        }
    }
}

extension Decimal {
    /// A typed amount: "25", "59.90", "1,250", "฿1,250.5". Nil for anything else, including more than 2 decimals.
    /// `Decimal(string:)` stopped at the first comma, so "1,250" saved as ฿1 (19 Oct).
    init?(baht text: String) {
        // Commas only as thousands groups: "1,5" (a decimal comma) is refused rather than read as 15.
        let trimmed = text.filter { !$0.isWhitespace && $0 != "฿" }
        guard trimmed.wholeMatch(of: /(\d+|\d{1,3}(,\d{3})+)(\.\d{1,2})?/) != nil,
              let value = Decimal(string: trimmed.replacingOccurrences(of: ",", with: "")) else { return nil }
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
