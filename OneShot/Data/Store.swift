import Foundation
import SwiftData

// The shop's books in SwiftData (one SQLite store in Application Support): sales and refunds, day closes, stock.
// `Sale`, `DayClose` and `StockLevel` stay plain values for the logic and tests; these records are how they're kept.

// The current shape. To change a model, add the next `StoreV<n>` (copying what changes), point these at it and add
// a `MigrationStage` to `StoreMigrations`. Never edit a version a build has shipped: its stores would stop opening.
typealias SaleRecord = StoreV3.SaleRecord
typealias LineRecord = StoreV3.LineRecord
typealias CloseRecord = StoreV3.CloseRecord
typealias StockRecord = StoreV3.StockRecord
typealias StockMoveRecord = StoreV3.StockMoveRecord
typealias ProductRecord = StoreV3.ProductRecord
typealias BarcodeRecord = StoreV3.BarcodeRecord
typealias TombstoneRecord = StoreV3.TombstoneRecord

/// The store's shape as first shipped (18 Oct). Frozen.
enum StoreV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [SaleRecord.self, LineRecord.self, CloseRecord.self, StockRecord.self] }

    @Model final class SaleRecord {
        #Unique<SaleRecord>([\.id])
        #Index<SaleRecord>([\.date], [\.refundOf])

        var id: UUID
        var date: Date
        var total: Decimal
        /// `PaymentMethod.rawValue`; nil for sales logged before cash existed (all PromptPay).
        var method: String?
        var received: Decimal?
        var refundOf: UUID?
        @Relationship(deleteRule: .cascade, inverse: \LineRecord.sale) var lines: [LineRecord] = []

        init(_ sale: Sale) {
            id = sale.id ?? UUID()
            date = sale.date
            total = sale.total
            method = sale.method?.rawValue
            received = sale.received
            refundOf = sale.refundOf
            lines = sale.lines.enumerated().map { LineRecord($1, position: $0) }
        }

        var sale: Sale {
            Sale(id: id, date: date,
                 lines: lines.sorted { $0.position < $1.position }.map {
                     SaleLine(sku: $0.sku, name: $0.name, quantity: $0.quantity, amount: $0.amount)
                 },
                 total: total, method: method.flatMap(PaymentMethod.init(rawValue:)), received: received, refundOf: refundOf)
        }
    }

    /// One line of a sale. SwiftData relationships are unordered, so `position` keeps the bill's order.
    @Model final class LineRecord {
        #Index<LineRecord>([\.sku])

        var sku: String
        var name: String
        var quantity: Int
        var amount: Decimal
        var position: Int
        var sale: SaleRecord?

        init(_ line: SaleLine, position: Int) {
            sku = line.sku
            name = line.name
            quantity = line.quantity
            amount = line.amount
            self.position = position
        }
    }

    @Model final class CloseRecord {
        var date: Date
        var float: Decimal
        var cashSales: Decimal
        var counted: Decimal
        var sales: Int
        var revenue: Decimal

        init(_ close: DayClose) {
            date = close.date
            float = close.float
            cashSales = close.cashSales
            counted = close.counted
            sales = close.sales
            revenue = close.revenue
        }

        var close: DayClose {
            DayClose(date: date, float: float, cashSales: cashSales, counted: counted, sales: sales, revenue: revenue)
        }
    }

    @Model final class StockRecord {
        #Unique<StockRecord>([\.sku])

        var sku: String
        var count: Int
        var reorderAt: Int

        init(sku: String, level: StockLevel) {
            self.sku = sku
            count = level.count
            reorderAt = level.reorderAt
        }

        var level: StockLevel { StockLevel(count: count, reorderAt: reorderAt) }
    }
}

/// V1 plus each sale's checkout speed, for analytics. Both new fields are optional, so a V1 store migrates lightweight.
/// Close and stock records didn't change and stay V1's; lines are copied because they pair with `SaleRecord`.
enum StoreV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [SaleRecord.self, LineRecord.self, CloseRecord.self, StockRecord.self] }

    typealias CloseRecord = StoreV1.CloseRecord
    typealias StockRecord = StoreV1.StockRecord

    @Model final class SaleRecord {
        #Unique<SaleRecord>([\.id])
        #Index<SaleRecord>([\.date], [\.refundOf])

        var id: UUID
        var date: Date
        var total: Decimal
        /// `PaymentMethod.rawValue`; nil for sales logged before cash existed (all PromptPay).
        var method: String?
        var received: Decimal?
        var refundOf: UUID?
        /// `Sale.ringUp` and `Sale.autoUnits`; nil for refunds and sales stored before V2.
        var ringUp: Double?
        var autoUnits: Int?
        @Relationship(deleteRule: .cascade, inverse: \LineRecord.sale) var lines: [LineRecord] = []

        init(_ sale: Sale) {
            id = sale.id ?? UUID()
            date = sale.date
            total = sale.total
            method = sale.method?.rawValue
            received = sale.received
            refundOf = sale.refundOf
            ringUp = sale.ringUp
            autoUnits = sale.autoUnits
            lines = sale.lines.enumerated().map { LineRecord($1, position: $0) }
        }

        var sale: Sale {
            Sale(id: id, date: date,
                 lines: lines.sorted { $0.position < $1.position }.map {
                     SaleLine(sku: $0.sku, name: $0.name, quantity: $0.quantity, amount: $0.amount)
                 },
                 total: total, method: method.flatMap(PaymentMethod.init(rawValue:)), received: received, refundOf: refundOf,
                 ringUp: ringUp, autoUnits: autoUnits)
        }
    }

    @Model final class LineRecord {
        #Index<LineRecord>([\.sku])

        var sku: String
        var name: String
        var quantity: Int
        var amount: Decimal
        var position: Int
        var sale: SaleRecord?

        init(_ line: SaleLine, position: Int) {
            sku = line.sku
            name = line.name
            quantity = line.quantity
            amount = line.amount
            self.position = position
        }
    }
}

/// How a store written by an older build reaches the current schema.
enum StoreMigrations: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [StoreV1.self, StoreV2.self, StoreV3.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: StoreV1.self, toVersion: StoreV2.self),
         .lightweight(fromVersion: StoreV2.self, toVersion: StoreV3.self)]
    }
}

@MainActor
enum Store {
    static let schema = Schema(versionedSchema: StoreV3.self)

    /// Where this launch put a store that wouldn't open. Home warns while it's set.
    static private(set) var setAside: URL?

    /// The app's store. One that won't open is set aside and the books start empty, never a crash at every launch.
    static let container: ModelContainer = {
        let (container, aside) = open(ModelConfiguration())
        setAside = aside
        importLegacyJSON(into: container.mainContext)
        Catalog.importLegacy(into: container.mainContext)
        return container
    }()

    static var context: ModelContext { container.mainContext }

    /// A throwaway store for tests and previews.
    static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: StoreMigrations.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Opens the store, migrating one an older build wrote. If it still won't open (corrupt, or from a newer build),
    /// its files move into a dated folder beside it, kept for recovery, and a fresh store opens in its place.
    static func open(_ configuration: ModelConfiguration) -> (ModelContainer, setAside: URL?) {
        func make() throws -> ModelContainer {
            try ModelContainer(for: schema, migrationPlan: StoreMigrations.self, configurations: configuration)
        }
        do {
            return (try make(), nil)
        } catch {
            Log.error("store not opened, setting it aside: \(error)")
        }
        let store = configuration.url
        let folder = store.deletingLastPathComponent()
        let aside = folder.appending(path: "Unreadable store \(Date.now.formatted(.iso8601.timeSeparator(.omitted)))")
        let files = ["", "-shm", "-wal"].map { folder.appending(path: store.lastPathComponent + $0) }
        var moved: [URL] = []
        // Crash with the books back where they were, never left aside while a later launch opens empty ones unwarned.
        func putBack(_ error: Error) -> Never {
            for file in moved { try? FileManager.default.moveItem(at: aside.appending(path: file.lastPathComponent), to: file) }
            fatalError("SwiftData store: \(error)")
        }
        do {
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            for file in files where FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try FileManager.default.moveItem(at: file, to: aside.appending(path: file.lastPathComponent))
                moved.append(file)
            }
        } catch {
            putBack(error)
        }
        do {
            return (try make(), aside)
        } catch {
            files.forEach { try? FileManager.default.removeItem(at: $0) }   // the fresh store that failed too (disk full?)
            putBack(error)
        }
    }

    /// Reads `sales.json`, `closings.json` and `stock.json` from `folder` into the store, then renames them `*.imported`:
    /// at launch, for the books earlier builds wrote and for a backup put back by hand (see `backUp`).
    /// Nothing in the store is overwritten: sales, closes and stock rows it already has are skipped (a `#Unique` upsert
    /// would keep a sale but double its lines, and live stock counts beat a backup's), and so is a second refund of one
    /// sale. A file that won't decode is left where it is (and logged), so nothing is lost.
    static func importLegacyJSON(into context: ModelContext, folder: URL = .documentsDirectory) {
        func take<T: Decodable>(_ name: String, as type: T.Type, insert: (T) throws -> Void) {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
            do {
                try insert(try JSONDecoder().decode(type, from: Data(contentsOf: url)))
                try context.save()
                let done = folder.appending(path: name + ".imported")
                try? FileManager.default.removeItem(at: done)   // an earlier import's; its rows are already in the store
                try FileManager.default.moveItem(at: url, to: done)
            } catch {
                context.rollback()
                Log.error("\(name) not imported: \(error)")
            }
        }
        take("sales.json", as: [Sale].self) { sales in
            let stored = try context.fetch(FetchDescriptor<SaleRecord>())
            var ids = Set(stored.map(\.id)), refunded = Set(stored.compactMap(\.refundOf))
            for sale in sales {   // the file is input, not trusted
                if let id = sale.id, !ids.insert(id).inserted { continue }
                if let original = sale.refundOf, !refunded.insert(original).inserted { continue }   // one refund per sale
                context.insert(SaleRecord(sale))
            }
        }
        take("closings.json", as: [DayClose].self) { closes in
            let kept = Set(try context.fetch(FetchDescriptor<CloseRecord>()).map(\.date))
            closes.filter { !kept.contains($0.date) }.forEach { context.insert(CloseRecord($0)) }
        }
        take("stock.json", as: [String: StockLevel].self) { levels in
            let kept = Set(try context.fetch(FetchDescriptor<StockRecord>()).map(\.sku))
            levels.filter { !kept.contains($0.key) }.forEach { context.insert(StockRecord(sku: $0.key, level: $0.value)) }
        }
    }

    /// The shop's own files beside the store, in Documents: the gallery's vectors and the photos they came from.
    /// A backup without them loses every taught product's look.
    nonisolated static let shopFiles = ["gallery.json", "Crops"]

    /// Writes the books as the files `importLegacyJSON` reads, the catalog as `products.json` and `barcodes.json`
    /// (what `Catalog.importBackup` reads), plus a copy of the shop files that exist.
    /// Restore with `restore(from:)`, or by hand: put them in OneShot's folder in the Files app and reopen the app.
    /// Throws rather than write a backup with anything missing.
    /// Nonisolated, on its own context: a big shop's books take seconds, so call it off the main actor.
    nonisolated static func backUp(_ container: ModelContainer, to folder: URL,
                                   documents: URL = .documentsDirectory) throws -> [URL] {
        let context = ModelContext(container)
        let sales = try context.fetch(FetchDescriptor<SaleRecord>(sortBy: [SortDescriptor(\.date)])).map(\.sale)
        let closes = try context.fetch(FetchDescriptor<CloseRecord>(sortBy: [SortDescriptor(\.date)])).map(\.close)
        let stock = try context.fetch(FetchDescriptor<StockRecord>()).map { ($0.sku, $0.level) }
        let products = try context.fetch(FetchDescriptor<ProductRecord>(sortBy: [SortDescriptor(\.id)])).map(\.product)
        let barcodes = try context.fetch(FetchDescriptor<BarcodeRecord>()).map { ($0.code, $0.sku) }
        let files = [("sales.json", try JSONEncoder().encode(sales)),
                     ("closings.json", try JSONEncoder().encode(closes)),
                     ("stock.json", try JSONEncoder().encode(Dictionary(stock, uniquingKeysWith: { first, _ in first }))),
                     ("products.json", try JSONEncoder().encode(products)),
                     ("barcodes.json", try JSONEncoder().encode(Dictionary(barcodes, uniquingKeysWith: { _, last in last })))]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let books = try files.map { name, data in
            let url = folder.appending(path: name)
            try data.write(to: url, options: .atomic)
            return url
        }
        return books + (try copyShopFiles(from: documents, to: folder))
    }

    /// What a backup folder holds, for the restore preview.
    struct BackupSummary: Equatable {
        var sales = 0, closes = 0, products = 0, photos = 0
    }

    nonisolated static func summary(of backup: URL) -> BackupSummary {
        func count<T: Decodable>(_ name: String, _ type: [T].Type) -> Int {
            (try? JSONDecoder().decode(type, from: Data(contentsOf: backup.appending(path: name))).count) ?? 0
        }
        let crops = FileManager.default.enumerator(at: backup.appending(path: "Crops"), includingPropertiesForKeys: nil)
        return BackupSummary(sales: count("sales.json", [Sale].self), closes: count("closings.json", [DayClose].self),
                             products: max(count("products.json", [Product].self), count("quickadd.json", [Product].self)),
                             photos: (crops?.allObjects as? [URL])?.filter { $0.pathExtension == "jpg" }.count ?? 0)
    }

    /// Puts a backup folder back: the products and shop files replace this device's, and the books are merged in by
    /// `importLegacyJSON` (nothing already in the store is doubled). Works on a copy, because the imports rename the
    /// files they read and the backup must stay as it is. The caller reloads the catalog and gallery afterwards.
    static func restore(from backup: URL, into context: ModelContext, documents: URL = .documentsDirectory) throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "Restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.copyItem(at: backup, to: work)
        _ = try copyShopFiles(from: work, to: documents)
        importLegacyJSON(into: context, folder: work)
        try Catalog.importBackup(from: work, into: context)
    }

    /// Everything this device holds for the shop: the books, catalog, stock, sync queue, gallery and photos, the shop's
    /// settings and the refund PIN. After an account is deleted, if the owner chooses; onboarding runs again.
    static func eraseEverything(in context: ModelContext, documents: URL = .documentsDirectory) throws {
        for model in StoreV3.models { try context.delete(model: model) }
        try context.save()
        for name in shopFiles {
            let url = documents.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { try FileManager.default.removeItem(at: url) }
        }
        try RefundPIN.save(nil)
        for key in [SettingsKey.shopName, SettingsKey.promptPayID, OnboardingKey.done] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Copies each shop file that exists in `source` over the one in `destination`.
    nonisolated private static func copyShopFiles(from source: URL, to destination: URL) throws -> [URL] {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        return try shopFiles.compactMap { name in
            let from = source.appending(path: name), to = destination.appending(path: name)
            guard manager.fileExists(atPath: from.path(percentEncoded: false)) else { return nil }
            if manager.fileExists(atPath: to.path(percentEncoded: false)) { try manager.removeItem(at: to) }
            try manager.copyItem(at: from, to: to)
            return to
        }
    }
}
