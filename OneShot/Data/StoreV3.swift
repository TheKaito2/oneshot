import Foundation
import SwiftData

/// V2 plus what an optional account needs to sync, and the catalog moved out of loose JSON files into the store.
/// Every new attribute is optional or defaulted, so a V2 store migrates lightweight.
///
/// Sync stamps: `syncedAt` nil = not on the server yet. Records that change (products, stock settings, closes, barcodes)
/// also carry `updatedAt`, pushed again whenever it is later than `syncedAt`; sales and stock moves never change.
/// Deletions leave a `TombstoneRecord`, so another device learns that a product or barcode is gone.
enum StoreV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SaleRecord.self, LineRecord.self, CloseRecord.self, StockRecord.self,
         ProductRecord.self, BarcodeRecord.self, StockMoveRecord.self, TombstoneRecord.self]
    }

    @Model final class SaleRecord {
        #Unique<SaleRecord>([\.id])
        #Index<SaleRecord>([\.date], [\.refundOf], [\.syncedAt])

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
        var syncedAt: Date?
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

    @Model final class CloseRecord {
        var date: Date
        var float: Decimal
        var cashSales: Decimal
        var counted: Decimal
        var sales: Int
        var revenue: Decimal
        var updatedAt: Date?
        var syncedAt: Date?

        init(_ close: DayClose) {
            date = close.date
            float = close.float
            cashSales = close.cashSales
            counted = close.counted
            sales = close.sales
            revenue = close.revenue
            updatedAt = .now
        }

        var close: DayClose {
            DayClose(date: date, float: float, cashSales: cashSales, counted: counted, sales: sales, revenue: revenue)
        }
    }

    /// A tracked product's shelf count and reorder point. The count moves by sales (each device's own, and synced
    /// ones applied as they arrive) and by `StockMoveRecord`s; the reorder point is a setting, last write wins.
    @Model final class StockRecord {
        #Unique<StockRecord>([\.sku])

        var sku: String
        var count: Int
        var reorderAt: Int
        var updatedAt: Date?
        var syncedAt: Date?

        init(sku: String, level: StockLevel) {
            self.sku = sku
            count = level.count
            reorderAt = level.reorderAt
            updatedAt = .now
        }

        var level: StockLevel { StockLevel(count: count, reorderAt: reorderAt) }
    }

    /// A change to a shelf count that isn't a sale: a delivery, or a recount (stored as the difference it made).
    /// Insert-only, so two devices changing the same count both land.
    @Model final class StockMoveRecord {
        #Unique<StockMoveRecord>([\.id])
        #Index<StockMoveRecord>([\.syncedAt])

        var id: UUID
        var sku: String
        var delta: Int
        /// "receive" or "count".
        var reason: String
        var at: Date
        var syncedAt: Date?

        init(sku: String, delta: Int, reason: String, at: Date = .now, id: UUID = UUID()) {
            self.id = id
            self.sku = sku
            self.delta = delta
            self.reason = reason
            self.at = at
        }
    }

    /// A product the shop sells. `id` is the detector's class label for the bundled ones, "qa-…" for taught ones.
    @Model final class ProductRecord {
        #Unique<ProductRecord>([\.id])

        var id: String
        var nameEN: String
        var nameTH: String
        var price: Decimal
        var cost: Decimal?
        var size: String?
        /// `ProductCategory.rawValue`.
        var category: String?
        /// The printed barcode that came with the catalog; ones scanned in the app are `BarcodeRecord`s.
        var barcode: String?
        var updatedAt: Date?
        var syncedAt: Date?

        init(_ product: Product) {
            id = product.id
            nameEN = product.nameEN
            nameTH = product.nameTH
            price = product.price
            cost = product.cost
            size = product.size
            category = product.category?.rawValue
            barcode = product.barcode
            updatedAt = .now
        }

        var product: Product {
            Product(id: id, nameEN: nameEN, nameTH: nameTH, price: price, barcode: barcode,
                    category: category.flatMap(ProductCategory.init(rawValue:)), cost: cost, size: size)
        }
    }

    /// A barcode scanned once in the app and tied to a product; wins over `ProductRecord.barcode`.
    @Model final class BarcodeRecord {
        #Unique<BarcodeRecord>([\.code])

        var code: String
        var sku: String
        var updatedAt: Date?
        var syncedAt: Date?

        init(code: String, sku: String) {
            self.code = code
            self.sku = sku
            updatedAt = .now
        }
    }

    /// Something deleted here that the server (and other devices) must delete too. `kind` names the table
    /// ("product", "barcode", "stock"), `key` its row.
    @Model final class TombstoneRecord {
        var kind: String
        var key: String
        var at: Date
        var syncedAt: Date?

        init(kind: String, key: String, at: Date = .now) {
            self.kind = kind
            self.key = key
            self.at = at
        }
    }
}
