import Foundation
import Observation
import Supabase
import SwiftData

/// Backs the shop up to Supabase and keeps the owner's devices in step, while signed in. The device stays the source
/// of truth and the till never waits on it: a sync that fails is retried at the next trigger.
///
/// The server contract (supabase/migrations): sales, sale lines and stock moves are insert-only (pushed with
/// "insert, ignore duplicates", so a retry can't double them); products, barcodes, stock levels, day closes and the
/// shop row are last-writer-wins on `edited_at`; deletions are soft (`deleted_at`). Every row gets a server
/// `updated_at`, the per-table pull cursor. Money goes as text both ways, so `Decimal` stays exact.
@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    private(set) var running = false
    private(set) var lastSynced: Date?
    private(set) var problem: String?
    /// Rows waiting to go up, for Settings.
    private(set) var pending = 0

    private let defaults = UserDefaults.standard
    private init() { lastSynced = defaults.object(forKey: "sync.lastSynced") as? Date }

    // MARK: - Running

    /// Push then pull. Does nothing signed out, offline-safe (errors are kept for Settings, never thrown at the till).
    func sync(_ app: AppModel) async {
        guard let client = Cloud.client, Account.shared.isSignedIn, !running else { return }
        running = true
        defer { running = false; countPending() }
        do {
            let context = Store.context
            let shop = try await shopID(client)
            try await pushShop(client, shop)
            try await push(client, shop, context)
            try await pull(client, shop, context, app)
            try await syncPhotos(client, shop, app)
            lastSynced = .now
            defaults.set(lastSynced, forKey: "sync.lastSynced")
            problem = nil
        } catch {
            problem = error.localizedDescription
            Log.error("sync failed: \(error)")
        }
    }

    /// Forgets which shop and cursors this device used: after sign-out or account deletion, the next account starts clean.
    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sync.") { defaults.removeObject(forKey: key) }
        lastSynced = nil
        problem = nil
    }

    func countPending() {
        let context = Store.context
        let unsynced = #Predicate<SaleRecord> { $0.syncedAt == nil }
        let moves = #Predicate<StockMoveRecord> { $0.syncedAt == nil }
        pending = ((try? context.fetchCount(FetchDescriptor(predicate: unsynced))) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor(predicate: moves))) ?? 0)
            + ((try? context.fetch(FetchDescriptor<ProductRecord>()).filter(Self.dirty).count) ?? 0)
    }

    private static func dirty(_ record: ProductRecord) -> Bool { record.syncedAt == nil || (record.updatedAt ?? .distantPast) > record.syncedAt! }

    // MARK: - The shop row

    /// This account's shop, created on first sign-in from this device's name and PromptPay ID.
    private func shopID(_ client: SupabaseClient) async throws -> UUID {
        if let stored = defaults.string(forKey: "sync.shop"), let id = UUID(uuidString: stored) { return id }
        struct Row: Decodable { let id: UUID }
        let existing: [Row] = try await client.from("shops").select("id").limit(1).execute().value
        let id: UUID
        if let row = existing.first {
            id = row.id
        } else {
            struct New: Encodable { let name: String; let promptpay_id: String? }
            let created: Row = try await client.from("shops")
                .insert(New(name: shopName, promptpay_id: promptPayID.isEmpty ? nil : promptPayID))
                .select("id").single().execute().value
            id = created.id
            defaults.set("\(shopName)|\(promptPayID)", forKey: "sync.shopPushed")
        }
        defaults.set(id.uuidString, forKey: "sync.shop")
        return id
    }

    private var shopName: String { defaults.string(forKey: SettingsKey.shopName) ?? "" }
    private var promptPayID: String { defaults.string(forKey: SettingsKey.promptPayID) ?? "" }

    /// The name and PromptPay ID go up when they changed here since the last push.
    private func pushShop(_ client: SupabaseClient, _ shop: UUID) async throws {
        let current = "\(shopName)|\(promptPayID)"
        guard defaults.string(forKey: "sync.shopPushed") != current else { return }
        struct Edit: Encodable { let name: String; let promptpay_id: String?; let edited_at: Date }
        try await client.from("shops")
            .update(Edit(name: shopName, promptpay_id: promptPayID.isEmpty ? nil : promptPayID, edited_at: .now))
            .eq("id", value: shop).execute()
        defaults.set(current, forKey: "sync.shopPushed")
    }

    // MARK: - Push

    private struct ProductRow: Codable {
        let shop_id: UUID, id: String, name_en: String, name_th: String, price: String
        let cost: String?, size: String?, category: String?, barcode: String?
        let edited_at: Date
        var deleted_at: Date? = nil
    }
    private struct BarcodeRow: Codable { let shop_id: UUID, code: String, sku: String, edited_at: Date; var deleted_at: Date? = nil }
    private struct StockRow: Codable { let shop_id: UUID, sku: String, count: Int, reorder_at: Int, edited_at: Date; var deleted_at: Date? = nil }
    private struct CloseRow: Codable {
        let shop_id: UUID, date: String, float: String, cash_sales: String, counted: String, sales: Int, revenue: String
        let edited_at: Date
    }
    private struct SaleRow: Codable {
        let shop_id: UUID, id: UUID, date: Date, total: String, method: String?, received: String?
        let ring_up: Double?, auto_units: Int?, refund_of: UUID?
    }
    private struct LineRow: Codable { let shop_id: UUID, sale_id: UUID, position: Int, sku: String, name: String, quantity: Int, amount: String }
    private struct MoveRow: Codable { let shop_id: UUID, id: UUID, sku: String, delta: Int, reason: String, at: Date }

    private func push(_ client: SupabaseClient, _ shop: UUID, _ context: ModelContext) async throws {
        // Products, barcodes, stock levels, closes: whatever changed since its last push. `syncedAt` becomes the
        // `updatedAt` that was pushed, so an edit made during the request still goes up next time.
        let products = try context.fetch(FetchDescriptor<ProductRecord>()).filter(Self.dirty)
        if !products.isEmpty {
            try await client.from("products").upsert(products.map {
                ProductRow(shop_id: shop, id: $0.id, name_en: $0.nameEN, name_th: $0.nameTH, price: "\($0.price)",
                           cost: $0.cost.map { "\($0)" }, size: $0.size, category: $0.category, barcode: $0.barcode,
                           edited_at: $0.updatedAt ?? .now)
            }, onConflict: "shop_id,id").execute()
            products.forEach { $0.syncedAt = $0.updatedAt ?? .now }
        }
        let barcodes = try context.fetch(FetchDescriptor<BarcodeRecord>())
            .filter { $0.syncedAt == nil || ($0.updatedAt ?? .distantPast) > $0.syncedAt! }
        if !barcodes.isEmpty {
            try await client.from("barcodes").upsert(barcodes.map {
                BarcodeRow(shop_id: shop, code: $0.code, sku: $0.sku, edited_at: $0.updatedAt ?? .now)
            }, onConflict: "shop_id,code").execute()
            barcodes.forEach { $0.syncedAt = $0.updatedAt ?? .now }
        }
        // Stock levels also go up when the count moved, so a new device starts from a recent count.
        var pushedCounts = defaults.dictionary(forKey: "sync.counts") as? [String: Int] ?? [:]
        let levels = try context.fetch(FetchDescriptor<StockRecord>()).filter {
            $0.syncedAt == nil || ($0.updatedAt ?? .distantPast) > $0.syncedAt! || pushedCounts[$0.sku] != $0.count
        }
        if !levels.isEmpty {
            try await client.from("stock_levels").upsert(levels.map {
                StockRow(shop_id: shop, sku: $0.sku, count: $0.count, reorder_at: $0.reorderAt, edited_at: $0.updatedAt ?? .now)
            }, onConflict: "shop_id,sku").execute()
            levels.forEach { $0.syncedAt = $0.updatedAt ?? .now; pushedCounts[$0.sku] = $0.count }
            defaults.set(pushedCounts, forKey: "sync.counts")
        }
        let closes = try context.fetch(FetchDescriptor<CloseRecord>())
            .filter { $0.syncedAt == nil || ($0.updatedAt ?? .distantPast) > $0.syncedAt! }
        if !closes.isEmpty {
            try await client.from("day_closes").upsert(closes.map {
                CloseRow(shop_id: shop, date: Self.day($0.date), float: "\($0.float)", cash_sales: "\($0.cashSales)",
                         counted: "\($0.counted)", sales: $0.sales, revenue: "\($0.revenue)", edited_at: $0.updatedAt ?? .now)
            }, onConflict: "shop_id,date").execute()
            closes.forEach { $0.syncedAt = $0.updatedAt ?? .now }
        }
        try context.save()

        // Sales and their lines: insert-only, oldest first so an original lands before its refund. 500 a request.
        let unsyncedSales = #Predicate<SaleRecord> { $0.syncedAt == nil }
        let sales = try context.fetch(FetchDescriptor(predicate: unsyncedSales, sortBy: [SortDescriptor(\.date)]))
        for batch in stride(from: 0, to: sales.count, by: 500).map({ Array(sales[$0..<min($0 + 500, sales.count)]) }) {
            try await client.from("sales").upsert(batch.map {
                SaleRow(shop_id: shop, id: $0.id, date: $0.date, total: "\($0.total)", method: $0.method,
                        received: $0.received.map { "\($0)" }, ring_up: $0.ringUp, auto_units: $0.autoUnits, refund_of: $0.refundOf)
            }, onConflict: "shop_id,id", ignoreDuplicates: true).execute()
            try await client.from("sale_lines").upsert(batch.flatMap { sale in
                sale.lines.map { LineRow(shop_id: shop, sale_id: sale.id, position: $0.position, sku: $0.sku, name: $0.name,
                                         quantity: $0.quantity, amount: "\($0.amount)") }
            }, onConflict: "shop_id,sale_id,position", ignoreDuplicates: true).execute()
            let now = Date.now
            batch.forEach { $0.syncedAt = now }
            try context.save()
        }

        let unsyncedMoves = #Predicate<StockMoveRecord> { $0.syncedAt == nil }
        let moves = try context.fetch(FetchDescriptor(predicate: unsyncedMoves))
        if !moves.isEmpty {
            try await client.from("stock_moves").upsert(moves.map {
                MoveRow(shop_id: shop, id: $0.id, sku: $0.sku, delta: $0.delta, reason: $0.reason, at: $0.at)
            }, onConflict: "shop_id,id", ignoreDuplicates: true).execute()
            let now = Date.now
            moves.forEach { $0.syncedAt = now }
            try context.save()
        }

        // Deletions: soft, with the deletion time as the edit, so a newer edit elsewhere still wins.
        let unsyncedTombstones = #Predicate<TombstoneRecord> { $0.syncedAt == nil }
        for tombstone in try context.fetch(FetchDescriptor(predicate: unsyncedTombstones)) {
            struct Delete: Encodable { let deleted_at: Date; let edited_at: Date }
            let (table, column) = switch tombstone.kind {
            case "product": ("products", "id")
            case "barcode": ("barcodes", "code")
            default: ("stock_levels", "sku")
            }
            try await client.from(table).update(Delete(deleted_at: tombstone.at, edited_at: tombstone.at))
                .eq("shop_id", value: shop).eq(column, value: tombstone.key).execute()
            tombstone.syncedAt = .now
        }
        try context.save()
    }

    // MARK: - Pull

    private struct PulledProduct: Decodable {
        let id: String, name_en: String, name_th: String, price: String
        let cost: String?, size: String?, category: String?, barcode: String?
        let deleted_at: Date?, edited_at: Date, updated_at: String
    }
    private struct PulledBarcode: Decodable { let code: String, sku: String, deleted_at: Date?, edited_at: Date, updated_at: String }
    private struct PulledStock: Decodable { let sku: String, count: Int, reorder_at: Int, deleted_at: Date?, edited_at: Date, updated_at: String }
    private struct PulledClose: Decodable {
        let date: String, float: String, cash_sales: String, counted: String, sales: Int, revenue: String
        let edited_at: Date, updated_at: String
    }
    private struct PulledLine: Decodable { let position: Int, sku: String, name: String, quantity: Int, amount: String }
    private struct PulledSale: Decodable {
        let id: UUID, date: Date, total: String, method: String?, received: String?
        let ring_up: Double?, auto_units: Int?, refund_of: UUID?, updated_at: String
        let sale_lines: [PulledLine]
    }
    private struct PulledMove: Decodable { let id: UUID, sku: String, delta: Int, reason: String, at: Date, updated_at: String }
    private struct PulledShop: Decodable { let name: String, promptpay_id: String?, updated_at: String }

    /// Rows another device changed since this one last looked, a page of 1,000 at a time. `apply` returns nothing;
    /// the cursor moves past each page only after it's applied and saved.
    private func pullTable<Row: Decodable & Sendable>(_ client: SupabaseClient, _ shop: UUID, _ table: String, columns: String,
                                                      cursor: (Row) -> String, apply: ([Row]) throws -> Void) async throws {
        let key = "sync.cursor.\(table)"
        while true {
            var query = client.from(table).select(columns).eq("shop_id", value: shop)
            if let after = defaults.string(forKey: key) { query = query.gt("updated_at", value: after) }
            let rows: [Row] = try await query.order("updated_at").limit(1000).execute().value
            guard let last = rows.last else { return }
            try apply(rows)
            try Store.context.save()
            defaults.set(cursor(last), forKey: key)
            if rows.count < 1000 { return }
        }
    }

    private func pull(_ client: SupabaseClient, _ shop: UUID, _ context: ModelContext, _ app: AppModel) async throws {
        // A device's very first pull restores the shop: its counts come from the server's stock levels, so the
        // sales and moves already in them aren't taken off a second time.
        let restoring = defaults.string(forKey: "sync.cursor.sales") == nil

        let shopRows: [PulledShop] = try await client.from("shops").select("name,promptpay_id,updated_at::text")
            .eq("id", value: shop).execute().value
        if let row = shopRows.first, row.updated_at != defaults.string(forKey: "sync.cursor.shops") {
            defaults.set(row.name, forKey: SettingsKey.shopName)
            defaults.set(row.promptpay_id ?? "", forKey: SettingsKey.promptPayID)
            defaults.set("\(row.name)|\(row.promptpay_id ?? "")", forKey: "sync.shopPushed")
            defaults.set(row.updated_at, forKey: "sync.cursor.shops")
        }

        let money = "price::text,cost::text"
        try await pullTable(client, shop, "products",
                            columns: "id,name_en,name_th,\(money),size,category,barcode,deleted_at,edited_at,updated_at::text",
                            cursor: { (row: PulledProduct) in row.updated_at }) { rows in
            let local = Dictionary(try context.fetch(FetchDescriptor<ProductRecord>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                let record = local[row.id]
                // A newer edit made here (not pushed yet) wins; it goes up next push.
                if let record, (record.updatedAt ?? .distantPast) > row.edited_at { continue }
                if row.deleted_at != nil {
                    if let record { context.delete(record) }
                    continue
                }
                let product = Product(id: row.id, nameEN: row.name_en, nameTH: row.name_th, price: Decimal(string: row.price) ?? 0,
                                      barcode: row.barcode, category: row.category.flatMap(ProductCategory.init(rawValue:)),
                                      cost: row.cost.flatMap { Decimal(string: $0) }, size: row.size)
                let target = record ?? { let new = ProductRecord(product); context.insert(new); return new }()
                target.nameEN = product.nameEN; target.nameTH = product.nameTH; target.price = product.price
                target.cost = product.cost; target.size = product.size; target.category = row.category; target.barcode = row.barcode
                target.updatedAt = row.edited_at
                target.syncedAt = row.edited_at
            }
        }
        try await pullTable(client, shop, "barcodes", columns: "code,sku,deleted_at,edited_at,updated_at::text",
                            cursor: { (row: PulledBarcode) in row.updated_at }) { rows in
            let local = Dictionary(try context.fetch(FetchDescriptor<BarcodeRecord>()).map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                let record = local[row.code]
                if let record, (record.updatedAt ?? .distantPast) > row.edited_at { continue }
                if row.deleted_at != nil {
                    if let record { context.delete(record) }
                    continue
                }
                let target = record ?? { let new = BarcodeRecord(code: row.code, sku: row.sku); context.insert(new); return new }()
                target.sku = row.sku
                target.updatedAt = row.edited_at
                target.syncedAt = row.edited_at
            }
        }
        try await pullTable(client, shop, "stock_levels", columns: "sku,count,reorder_at,deleted_at,edited_at,updated_at::text",
                            cursor: { (row: PulledStock) in row.updated_at }) { rows in
            for row in rows {
                if row.deleted_at != nil {
                    app.stock.untrack(row.sku)
                } else if app.stock[row.sku] != nil {
                    // Tracked here: keep this device's count (sales and moves move it); take the reorder point.
                    app.stock.setReorder(row.sku, reorderAt: row.reorder_at)
                } else {
                    app.stock.track(row.sku, count: row.count, reorderAt: row.reorder_at)
                }
            }
        }
        try await pullTable(client, shop, "day_closes",
                            columns: "date,float::text,cash_sales::text,counted::text,sales,revenue::text,edited_at,updated_at::text",
                            cursor: { (row: PulledClose) in row.updated_at }) { rows in
            let local = try context.fetch(FetchDescriptor<CloseRecord>())
            for row in rows {
                let date = Self.date(fromDay: row.date)
                let existing = local.first { Self.day($0.date) == row.date }
                if let existing, (existing.updatedAt ?? .distantPast) > row.edited_at { continue }
                let close = DayClose(date: existing?.date ?? date, float: Decimal(string: row.float) ?? 0,
                                     cashSales: Decimal(string: row.cash_sales) ?? 0, counted: Decimal(string: row.counted) ?? 0,
                                     sales: row.sales, revenue: Decimal(string: row.revenue) ?? 0)
                if let existing { context.delete(existing) }
                let record = CloseRecord(close)
                record.updatedAt = row.edited_at
                record.syncedAt = row.edited_at
                context.insert(record)
            }
        }
        let lines = "sale_lines(position,sku,name,quantity,amount::text)"
        try await pullTable(client, shop, "sales",
                            columns: "id,date,total::text,method,received::text,ring_up,auto_units,refund_of,updated_at::text,\(lines)",
                            cursor: { (row: PulledSale) in row.updated_at }) { rows in
            let ids = rows.map(\.id)
            let have = Set(try context.fetch(FetchDescriptor<SaleRecord>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
            for row in rows where !have.contains(row.id) {
                let sale = Sale(id: row.id, date: row.date,
                                lines: row.sale_lines.sorted { $0.position < $1.position }.map {
                                    SaleLine(sku: $0.sku, name: $0.name, quantity: $0.quantity, amount: Decimal(string: $0.amount) ?? 0)
                                },
                                total: Decimal(string: row.total) ?? 0, method: row.method.flatMap(PaymentMethod.init(rawValue:)),
                                received: row.received.flatMap { Decimal(string: $0) }, refundOf: row.refund_of,
                                ringUp: row.ring_up, autoUnits: row.auto_units)
                let record = SaleRecord(sale)
                record.syncedAt = .now
                context.insert(record)
                if !restoring { app.stock.apply(sale) }
            }
        }
        try await pullTable(client, shop, "stock_moves", columns: "id,sku,delta,reason,at,updated_at::text",
                            cursor: { (row: PulledMove) in row.updated_at }) { rows in
            let ids = rows.map(\.id)
            let have = Set(try context.fetch(FetchDescriptor<StockMoveRecord>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
            for row in rows where !have.contains(row.id) {
                let record = StockMoveRecord(sku: row.sku, delta: row.delta, reason: row.reason, at: row.at, id: row.id)
                record.syncedAt = .now
                context.insert(record)
                if !restoring { app.stock.applyRemote(row.sku, delta: row.delta) }
            }
        }
        app.saveStock()
        app.reloadCatalog()
    }

    // MARK: - Photos

    /// Taught products' photos: each new local one goes up; a product with none here comes down, and the gallery
    /// re-embeds it on this device (FeaturePrint vectors can differ between device models, so they never sync).
    private func syncPhotos(_ client: SupabaseClient, _ shop: UUID, _ app: AppModel) async throws {
        let bucket = client.storage.from("product-photos")
        var uploaded = Set(defaults.stringArray(forKey: "sync.photos") ?? [])
        for product in app.catalog.products where Catalog.isQuickAdd(product.id) {
            let local = CropStore.photos(for: product.id)
            if local.isEmpty {
                let folder = "\(shop.uuidString.lowercased())/\(product.id)"
                let files = try await bucket.list(path: folder)
                guard !files.isEmpty else { continue }
                for file in files {
                    let data = try await bucket.download(path: "\(folder)/\(file.name)")
                    CropStore.write(data, to: "Crops/\(product.id)/\(file.name)")
                    uploaded.insert("\(folder)/\(file.name)")
                }
                let gallery = app.gallery, sku = product.id
                await Task.detached(priority: .utility) { gallery.rebuild(sku) }.value
            } else {
                for url in local {
                    let path = "\(shop.uuidString.lowercased())/\(product.id)/\(url.lastPathComponent)"
                    guard !uploaded.contains(path) else { continue }
                    try await bucket.upload(path, data: try Data(contentsOf: url),
                                            options: FileOptions(contentType: "image/jpeg", upsert: true))
                    uploaded.insert(path)
                }
            }
        }
        defaults.set(Array(uploaded), forKey: "sync.photos")
    }

    // MARK: - Days

    /// A close's day in Thailand, as the server's `date` column.
    private static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "Asia/Bangkok")!).year().month().day())
    }

    private static func date(fromDay day: String) -> Date {
        (try? Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "Asia/Bangkok")!).year().month().day().parse(day)) ?? .now
    }
}
