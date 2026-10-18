import Foundation
import SwiftData

// The shop's books in SwiftData (one SQLite store in Application Support): sales and refunds, day closes, stock.
// `Sale`, `DayClose` and `StockLevel` stay plain values for the logic and tests; these records are how they're kept.

// The current shape. To change a model, add the next `StoreV<n>` (copying what changes), point these at it and add
// a `MigrationStage` to `StoreMigrations`. Never edit a version a build has shipped: its stores would stop opening.
typealias SaleRecord = StoreV2.SaleRecord
typealias LineRecord = StoreV2.LineRecord
typealias CloseRecord = StoreV2.CloseRecord
typealias StockRecord = StoreV2.StockRecord

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
    static var schemas: [any VersionedSchema.Type] { [StoreV1.self, StoreV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: StoreV1.self, toVersion: StoreV2.self)] }
}

@MainActor
enum Store {
    static let schema = Schema(versionedSchema: StoreV2.self)

    /// Where this launch put a store that wouldn't open. Home warns while it's set.
    static private(set) var setAside: URL?

    /// The app's store. One that won't open is set aside and the books start empty, never a crash at every launch.
    static let container: ModelContainer = {
        let (container, aside) = open(ModelConfiguration())
        setAside = aside
        importLegacyJSON(into: container.mainContext)
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
            print("store not opened, setting it aside: \(error)")
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
                print("\(name) not imported: \(error)")
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

    /// Writes the books as the three files `importLegacyJSON` reads, so restoring is: put them in OneShot's folder in
    /// the Files app (Documents) and reopen the app. Throws rather than write a backup with anything missing.
    /// Nonisolated, on its own context: a big shop's books take seconds, so call it off the main actor.
    nonisolated static func backUp(_ container: ModelContainer, to folder: URL) throws -> [URL] {
        let context = ModelContext(container)
        let sales = try context.fetch(FetchDescriptor<SaleRecord>(sortBy: [SortDescriptor(\.date)])).map(\.sale)
        let closes = try context.fetch(FetchDescriptor<CloseRecord>(sortBy: [SortDescriptor(\.date)])).map(\.close)
        let stock = try context.fetch(FetchDescriptor<StockRecord>()).map { ($0.sku, $0.level) }
        let files = [("sales.json", try JSONEncoder().encode(sales)),
                     ("closings.json", try JSONEncoder().encode(closes)),
                     ("stock.json", try JSONEncoder().encode(Dictionary(stock, uniquingKeysWith: { first, _ in first })))]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.map { name, data in
            let url = folder.appending(path: name)
            try data.write(to: url, options: .atomic)
            return url
        }
    }
}
