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
/// `updated_at`, which with the row's key is the per-table pull cursor. Money goes as text both ways, so `Decimal`
/// stays exact.
///
/// A device that has never synced restores first (the server wins), then pushes what it has that the server doesn't.
/// A device is bound to the first account that synced it: another account must erase it first, so two shops never mix.
@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()
    /// The account whose shop this device holds. Not a `sync.` key: sign-out keeps it, only erasing the device clears it.
    static let ownerKey = "syncOwner"

    private(set) var running = false
    private(set) var lastSynced: Date?
    private(set) var problem: String?
    /// Rows waiting to go up, for Settings.
    private(set) var pending = 0

    private let defaults = UserDefaults.standard
    /// Bumped by `reset()`: a sync already in flight sees it and stops before writing any more state.
    private var generation = 0

    private init() { lastSynced = defaults.object(forKey: "sync.lastSynced") as? Date }

    private struct Cancelled: Error {}
    private struct OtherAccount: LocalizedError {
        var errorDescription: String? {
            String(localized: "This device holds another account's shop. To sync with this account, erase this device first (sign in with the other account and delete it, or reinstall OneShot).")
        }
    }

    // MARK: - Running

    /// Restore (first time), push, pull, photos. Does nothing signed out; errors are kept for Settings, never thrown at
    /// the till. One table the server rejects doesn't stop the others.
    func sync(_ app: AppModel) async {
        guard let client = Cloud.client, Account.shared.isSignedIn, !running else { return }
        running = true
        let generation = self.generation
        defer { running = false; countPending() }
        do {
            let user = try await client.auth.session.user.id.uuidString
            if let owner = defaults.string(forKey: Self.ownerKey), owner != user { throw OtherAccount() }
            let shop = try await shopID(client)
            try check(generation)
            defaults.set(user, forKey: Self.ownerKey)
            let context = Store.context
            if !defaults.bool(forKey: "sync.restored") {
                try await pull(client, shop, context, app, restoring: true, generation: generation)
                defaults.set(true, forKey: "sync.restored")
            }
            var failures: [String] = []
            try await pushShop(client, shop)
            try await push(client, shop, context, generation: generation, failures: &failures)
            try await pull(client, shop, context, app, restoring: false, generation: generation)
            try await syncPhotos(client, shop, app, generation: generation)
            // Training photos never hold up the shop's own backup: their trouble is logged, not reported.
            do {
                if defaults.bool(forKey: TrainingSamples.withdrawPendingKey) {
                    _ = try await setTrainingConsent(false)
                    defaults.set(false, forKey: TrainingSamples.withdrawPendingKey)
                }
                try await sendTraining(client, shop, generation: generation)
            } catch is Cancelled {
                throw Cancelled()
            } catch {
                Log.error("training photos: \(error)")
            }
            lastSynced = .now
            defaults.set(lastSynced, forKey: "sync.lastSynced")
            problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch is Cancelled {
            return
        } catch {
            problem = error.localizedDescription
            Log.error("sync failed: \(error)")
        }
    }

    /// Forgets the shop, cursors and push state (sign-out, account deleted). The device keeps its owner binding.
    func reset() {
        generation += 1
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sync.") { defaults.removeObject(forKey: key) }
        lastSynced = nil
        problem = nil
    }

    private func check(_ generation: Int) throws {
        if generation != self.generation { throw Cancelled() }
    }

    func countPending() {
        let context = Store.context
        let unsynced = #Predicate<SaleRecord> { $0.syncedAt == nil }
        let moves = #Predicate<StockMoveRecord> { $0.syncedAt == nil }
        pending = ((try? context.fetchCount(FetchDescriptor(predicate: unsynced))) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor(predicate: moves))) ?? 0)
            + ((try? context.fetch(FetchDescriptor<ProductRecord>()).filter { Self.dirty($0.updatedAt, $0.syncedAt) }.count) ?? 0)
    }

    private static func dirty(_ updated: Date?, _ synced: Date?) -> Bool {
        guard let synced else { return true }
        return (updated ?? .distantPast) > synced
    }

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
            defaults.set(shopPair, forKey: "sync.shopPushed")
        }
        defaults.set(id.uuidString, forKey: "sync.shop")
        return id
    }

    private var shopName: String { defaults.string(forKey: SettingsKey.shopName) ?? "" }
    private var promptPayID: String { defaults.string(forKey: SettingsKey.promptPayID) ?? "" }
    private var shopPair: String { "\(shopName)|\(promptPayID)" }

    /// The name and PromptPay ID go up when they changed here since the last push or pull.
    private func pushShop(_ client: SupabaseClient, _ shop: UUID) async throws {
        let pair = shopPair, name = shopName, id = promptPayID
        guard defaults.string(forKey: "sync.shopPushed") != pair else { return }
        struct Edit: Encodable { let name: String; let promptpay_id: String?; let edited_at: Date }
        try await client.from("shops").update(Edit(name: name, promptpay_id: id.isEmpty ? nil : id, edited_at: .now))
            .eq("id", value: shop).execute()
        defaults.set(pair, forKey: "sync.shopPushed")
    }

    // MARK: - Push

    /// Encodes as `null` when nil (an optional property would be left out), so an upsert clears an earlier soft delete.
    private struct Nullable<Value: Encodable & Sendable>: Encodable, Sendable {
        let value: Value?
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value { try container.encode(value) } else { try container.encodeNil() }
        }
    }

    private struct ProductRow: Encodable, Sendable {
        let shop_id: UUID, id: String, name_en: String, name_th: String, price: String
        let cost: Nullable<String>, size: Nullable<String>, category: Nullable<String>, barcode: Nullable<String>
        let edited_at: Date, deleted_at = Nullable<Date>(value: nil)
    }
    private struct BarcodeRow: Encodable, Sendable {
        let shop_id: UUID, code: String, sku: String, edited_at: Date, deleted_at = Nullable<Date>(value: nil)
    }
    private struct StockRow: Encodable, Sendable {
        let shop_id: UUID, sku: String, count: Int, reorder_at: Int, edited_at: Date, deleted_at = Nullable<Date>(value: nil)
    }
    private struct CloseRow: Encodable, Sendable {
        let shop_id: UUID, date: String, float: String, cash_sales: String, counted: String, sales: Int, revenue: String
        let edited_at: Date
    }
    private struct SaleRow: Encodable, Sendable {
        let shop_id: UUID, id: UUID, date: Date, total: String, method: String?, received: String?
        let ring_up: Double?, auto_units: Int?, refund_of: UUID?
    }
    private struct LineRow: Encodable, Sendable {
        let shop_id: UUID, sale_id: UUID, position: Int, sku: String, name: String, quantity: Int, amount: String
    }
    private struct MoveRow: Encodable, Sendable { let shop_id: UUID, id: UUID, sku: String, delta: Int, reason: String, at: Date }

    /// Runs one table's push; a failure is recorded and the other tables still go.
    private func attempt(_ table: String, _ failures: inout [String], _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch let error as Cancelled {
            throw error
        } catch {
            Log.error("sync push \(table) failed: \(error)")
            failures.append(String(localized: "Couldn't back up \(table): \(error.localizedDescription)"))
        }
    }

    private func push(_ client: SupabaseClient, _ shop: UUID, _ context: ModelContext, generation: Int,
                      failures: inout [String]) async throws {
        // Each row is stamped with the `updatedAt` read before the request, so an edit made while it is in flight
        // (a newer `updatedAt`) still counts as unsynced and goes up next time.
        try await attempt("products", &failures) {
            let records = try context.fetch(FetchDescriptor<ProductRecord>()).filter { Self.dirty($0.updatedAt, $0.syncedAt) }
            guard !records.isEmpty else { return }
            let stamped = records.map { ($0, $0.updatedAt ?? .now) }
            try await client.from("products").upsert(stamped.map { record, stamp in
                ProductRow(shop_id: shop, id: record.id, name_en: record.nameEN, name_th: record.nameTH, price: "\(record.price)",
                           cost: Nullable(value: record.cost.map { "\($0)" }), size: Nullable(value: record.size),
                           category: Nullable(value: record.category), barcode: Nullable(value: record.barcode), edited_at: stamp)
            }, onConflict: "shop_id,id").execute()
            try check(generation)
            stamped.forEach { $0.syncedAt = $1 }
            try context.save()
        }
        try await attempt("barcodes", &failures) {
            let records = try context.fetch(FetchDescriptor<BarcodeRecord>()).filter { Self.dirty($0.updatedAt, $0.syncedAt) }
            guard !records.isEmpty else { return }
            let stamped = records.map { ($0, $0.updatedAt ?? .now) }
            try await client.from("barcodes").upsert(stamped.map {
                BarcodeRow(shop_id: shop, code: $0.code, sku: $0.sku, edited_at: $1)
            }, onConflict: "shop_id,code").execute()
            try check(generation)
            stamped.forEach { $0.syncedAt = $1 }
            try context.save()
        }
        try await attempt("stock", &failures) {
            // Levels also go up when the count moved, so a new device restores from a recent count.
            var pushedCounts = defaults.dictionary(forKey: "sync.counts") as? [String: Int] ?? [:]
            let records = try context.fetch(FetchDescriptor<StockRecord>()).filter {
                Self.dirty($0.updatedAt, $0.syncedAt) || pushedCounts[$0.sku] != $0.count
            }
            guard !records.isEmpty else { return }
            // ponytail: a count-only push carries the row's old edited_at, so the server skips it when another
            // device set the reorder point later; that device's next push carries its own count instead.
            let stamped = records.map { (record: $0, stamp: $0.updatedAt ?? .now, count: $0.count) }
            try await client.from("stock_levels").upsert(stamped.map {
                StockRow(shop_id: shop, sku: $0.record.sku, count: $0.count, reorder_at: $0.record.reorderAt, edited_at: $0.stamp)
            }, onConflict: "shop_id,sku").execute()
            try check(generation)
            for item in stamped {
                item.record.syncedAt = item.stamp
                pushedCounts[item.record.sku] = item.count
            }
            defaults.set(pushedCounts, forKey: "sync.counts")
            try context.save()
        }
        try await attempt("day closes", &failures) {
            let records = try context.fetch(FetchDescriptor<CloseRecord>()).filter { Self.dirty($0.updatedAt, $0.syncedAt) }
            guard !records.isEmpty else { return }
            // One row per Bangkok day: two closes of one day in one upsert would be rejected, so the latest goes.
            let latest = Dictionary(grouping: records) { Self.day($0.date) }.compactMapValues {
                $0.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            }
            let stamped = records.map { ($0, $0.updatedAt ?? .now) }
            try await client.from("day_closes").upsert(latest.map { day, record in
                CloseRow(shop_id: shop, date: day, float: "\(record.float)", cash_sales: "\(record.cashSales)",
                         counted: "\(record.counted)", sales: record.sales, revenue: "\(record.revenue)",
                         edited_at: record.updatedAt ?? .now)
            }, onConflict: "shop_id,date").execute()
            try check(generation)
            stamped.forEach { $0.syncedAt = $1 }
            try context.save()
        }
        try await attempt("sales", &failures) { try await pushSales(client, shop, context, generation) }
        try await attempt("stock moves", &failures) {
            let unsynced = #Predicate<StockMoveRecord> { $0.syncedAt == nil }
            let moves = try context.fetch(FetchDescriptor(predicate: unsynced))
            guard !moves.isEmpty else { return }
            try await client.from("stock_moves").upsert(moves.map {
                MoveRow(shop_id: shop, id: $0.id, sku: $0.sku, delta: $0.delta, reason: $0.reason, at: $0.at)
            }, onConflict: "shop_id,id", ignoreDuplicates: true).execute()
            try check(generation)
            let now = Date.now
            moves.forEach { $0.syncedAt = now }
            try context.save()
        }
        try await attempt("deletions", &failures) {
            // Soft, with the deletion time as the edit, so a newer edit elsewhere still wins.
            let unsynced = #Predicate<TombstoneRecord> { $0.syncedAt == nil }
            for tombstone in try context.fetch(FetchDescriptor(predicate: unsynced)) {
                struct Delete: Encodable { let deleted_at: Date; let edited_at: Date }
                let (table, column) = switch tombstone.kind {
                case "product": ("products", "id")
                case "barcode": ("barcodes", "code")
                default: ("stock_levels", "sku")
                }
                try await client.from(table).update(Delete(deleted_at: tombstone.at, edited_at: tombstone.at))
                    .eq("shop_id", value: shop).eq(column, value: tombstone.key).execute()
                try check(generation)
                tombstone.syncedAt = .now
            }
            try context.save()
        }
    }

    /// Sales and their lines, oldest first so an original lands before its refund, 200 a request. A batch the server
    /// rejects is retried a sale at a time, and a sale it still rejects (say, a second refund of one sale made offline on
    /// another device) is set aside (`syncedAt` = distant past, logged) so it can't block every later sale.
    private func pushSales(_ client: SupabaseClient, _ shop: UUID, _ context: ModelContext, _ generation: Int) async throws {
        let unsynced = #Predicate<SaleRecord> { $0.syncedAt == nil }
        let sales = try context.fetch(FetchDescriptor(predicate: unsynced, sortBy: [SortDescriptor(\.date)]))
        func send(_ batch: [SaleRecord]) async throws {
            try await client.from("sales").upsert(batch.map {
                SaleRow(shop_id: shop, id: $0.id, date: $0.date, total: "\($0.total)", method: $0.method,
                        received: $0.received.map { "\($0)" }, ring_up: $0.ringUp, auto_units: $0.autoUnits, refund_of: $0.refundOf)
            }, onConflict: "shop_id,id", ignoreDuplicates: true).execute()
            try await client.from("sale_lines").upsert(batch.flatMap { sale in
                sale.lines.map { LineRow(shop_id: shop, sale_id: sale.id, position: $0.position, sku: $0.sku, name: $0.name,
                                         quantity: $0.quantity, amount: "\($0.amount)") }
            }, onConflict: "shop_id,sale_id,position", ignoreDuplicates: true).execute()
        }
        for start in stride(from: 0, to: sales.count, by: 200) {
            let batch = Array(sales[start..<min(start + 200, sales.count)])
            do {
                try await send(batch)
                batch.forEach { $0.syncedAt = .now }
            } catch {
                for sale in batch {
                    do {
                        try await send([sale])
                        sale.syncedAt = .now
                    } catch {
                        Log.error("sale \(sale.id) rejected by the server, set aside: \(error)")
                        sale.syncedAt = .distantPast
                    }
                }
            }
            try check(generation)
            try context.save()
        }
    }

    // MARK: - Pull

    private struct PulledProduct: Decodable, Sendable {
        let id: String, name_en: String, name_th: String, price: String
        let cost: String?, size: String?, category: String?, barcode: String?
        let deleted_at: Date?, edited_at: Date, updated_at: String
    }
    private struct PulledBarcode: Decodable, Sendable { let code: String, sku: String, deleted_at: Date?, edited_at: Date, updated_at: String }
    private struct PulledStock: Decodable, Sendable { let sku: String, count: Int, reorder_at: Int, deleted_at: Date?, updated_at: String }
    private struct PulledClose: Decodable, Sendable {
        let date: String, float: String, cash_sales: String, counted: String, sales: Int, revenue: String
        let edited_at: Date, updated_at: String
    }
    private struct PulledLine: Decodable, Sendable { let position: Int, sku: String, name: String, quantity: Int, amount: String }
    private struct PulledSale: Decodable, Sendable {
        let id: UUID, date: Date, total: String, method: String?, received: String?
        let ring_up: Double?, auto_units: Int?, refund_of: UUID?, updated_at: String
        let sale_lines: [PulledLine]
    }
    private struct PulledMove: Decodable, Sendable { let id: UUID, sku: String, delta: Int, reason: String, at: Date, updated_at: String }
    private struct PulledShop: Decodable, Sendable { let name: String, promptpay_id: String?, updated_at: String }

    /// Rows changed since this device last looked, 500 a page, in (updated_at, key) order: one upsert stamps many rows
    /// with the same updated_at, so the key breaks ties and a page boundary can't skip any. `apply` returns how many of
    /// the page it took (it may stop early to fetch the rest later); the cursor moves past those only, after they're saved.
    private func pullTable<Row: Decodable & Sendable>(_ client: SupabaseClient, _ shop: UUID, _ table: String, key keyColumn: String,
                                                      columns: String, generation: Int, rowKey: (Row) -> String,
                                                      updated: (Row) -> String, apply: ([Row]) throws -> Int) async throws {
        let cursorKey = "sync.cursor.\(table)", tieKey = "sync.cursorKey.\(table)"
        while true {
            var query = client.from(table).select(columns).eq("shop_id", value: shop)
            if let after = defaults.string(forKey: cursorKey), let tie = defaults.string(forKey: tieKey) {
                query = query.or("updated_at.gt.\"\(after)\",and(updated_at.eq.\"\(after)\",\(keyColumn).gt.\"\(tie)\")")
            }
            let rows: [Row] = try await query.order("updated_at").order(keyColumn).limit(500).execute().value
            try check(generation)
            guard !rows.isEmpty else { return }
            let taken = try apply(rows)
            try Store.context.save()
            guard taken > 0 else { return }
            let last = rows[taken - 1]
            defaults.set(Self.cursor(updated(last)), forKey: cursorKey)
            defaults.set(rowKey(last), forKey: tieKey)
            if taken < rows.count || rows.count < 500 { return }
        }
    }

    /// Postgres prints `...+00`; a "+" in a URL query can be read as a space, so the cursor uses "Z" instead.
    private static func cursor(_ text: String) -> String {
        text.hasSuffix("+00") ? String(text.dropLast(3)) + "Z" : text
    }

    private func pull(_ client: SupabaseClient, _ shop: UUID, _ context: ModelContext, _ app: AppModel,
                      restoring: Bool, generation: Int) async throws {
        // The shop row: restoring takes the server's; later, only when nothing changed here since the last push.
        let shopRows: [PulledShop] = try await client.from("shops").select("name,promptpay_id,updated_at::text")
            .eq("id", value: shop).execute().value
        try check(generation)
        if let row = shopRows.first, row.updated_at != defaults.string(forKey: "sync.cursor.shops"),
           restoring || defaults.string(forKey: "sync.shopPushed") == shopPair {
            defaults.set(row.name, forKey: SettingsKey.shopName)
            defaults.set(row.promptpay_id ?? "", forKey: SettingsKey.promptPayID)
            defaults.set(shopPair, forKey: "sync.shopPushed")
            defaults.set(row.updated_at, forKey: "sync.cursor.shops")
        }

        try await pullTable(client, shop, "products", key: "id",
                            columns: "id,name_en,name_th,price::text,cost::text,size,category,barcode,deleted_at,edited_at,updated_at::text",
                            generation: generation, rowKey: { (row: PulledProduct) in row.id }, updated: { $0.updated_at }) { rows in
            let local = Dictionary(try context.fetch(FetchDescriptor<ProductRecord>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                let record = local[row.id]
                // A newer edit made here (not pushed yet) wins; it goes up next push. Restoring, the server wins.
                if !restoring, let record, (record.updatedAt ?? .distantPast) > row.edited_at { continue }
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
            return rows.count
        }
        try await pullTable(client, shop, "barcodes", key: "code", columns: "code,sku,deleted_at,edited_at,updated_at::text",
                            generation: generation, rowKey: { (row: PulledBarcode) in row.code }, updated: { $0.updated_at }) { rows in
            let local = Dictionary(try context.fetch(FetchDescriptor<BarcodeRecord>()).map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
            for row in rows {
                let record = local[row.code]
                if !restoring, let record, (record.updatedAt ?? .distantPast) > row.edited_at { continue }
                if row.deleted_at != nil {
                    if let record { context.delete(record) }
                    continue
                }
                let target = record ?? { let new = BarcodeRecord(code: row.code, sku: row.sku); context.insert(new); return new }()
                target.sku = row.sku
                target.updatedAt = row.edited_at
                target.syncedAt = row.edited_at
            }
            return rows.count
        }
        try await pullTable(client, shop, "day_closes", key: "date",
                            columns: "date,float::text,cash_sales::text,counted::text,sales,revenue::text,edited_at,updated_at::text",
                            generation: generation, rowKey: { (row: PulledClose) in row.date }, updated: { $0.updated_at }) { rows in
            let local = try context.fetch(FetchDescriptor<CloseRecord>())
            for row in rows {
                let existing = local.first { Self.day($0.date) == row.date }
                if !restoring, let existing, (existing.updatedAt ?? .distantPast) > row.edited_at { continue }
                let close = DayClose(date: existing?.date ?? Self.date(fromDay: row.date), float: Decimal(string: row.float) ?? 0,
                                     cashSales: Decimal(string: row.cash_sales) ?? 0, counted: Decimal(string: row.counted) ?? 0,
                                     sales: row.sales, revenue: Decimal(string: row.revenue) ?? 0)
                if let existing { context.delete(existing) }
                let record = CloseRecord(close)
                record.updatedAt = row.edited_at
                record.syncedAt = row.edited_at
                context.insert(record)
            }
            return rows.count
        }
        // Sales and moves another device made take their stock off here too, saved with each page. Restoring, they're
        // already in the server's counts (taken last, below), so they're stored without moving stock.
        try await pullTable(client, shop, "sales", key: "id",
                            columns: "id,date,total::text,method,received::text,ring_up,auto_units,refund_of,updated_at::text,sale_lines(position,sku,name,quantity,amount::text)",
                            generation: generation, rowKey: { (row: PulledSale) in row.id.uuidString.lowercased() }, updated: { $0.updated_at }) { rows in
            // A sale's lines go up just after it: one pulled in between has none yet. Stop there and fetch it again later.
            let complete = rows.prefix { !$0.sale_lines.isEmpty || Decimal(string: $0.total) == 0 }
            let ids = complete.map(\.id)
            let have = Set(try context.fetch(FetchDescriptor<SaleRecord>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
            for row in complete where !have.contains(row.id) {
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
            if !restoring { app.saveStock() }
            return complete.count
        }
        try await pullTable(client, shop, "stock_moves", key: "id", columns: "id,sku,delta,reason,at,updated_at::text",
                            generation: generation, rowKey: { (row: PulledMove) in row.id.uuidString.lowercased() }, updated: { $0.updated_at }) { rows in
            let ids = rows.map(\.id)
            let have = Set(try context.fetch(FetchDescriptor<StockMoveRecord>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
            for row in rows where !have.contains(row.id) {
                let record = StockMoveRecord(sku: row.sku, delta: row.delta, reason: row.reason, at: row.at, id: row.id)
                record.syncedAt = .now
                context.insert(record)
                if !restoring { app.stock.applyRemote(row.sku, delta: row.delta) }
            }
            if !restoring { app.saveStock() }
            return rows.count
        }
        // Last, so a restore starts from the newest counts the other devices pushed.
        try await pullTable(client, shop, "stock_levels", key: "sku", columns: "sku,count,reorder_at,deleted_at,updated_at::text",
                            generation: generation, rowKey: { (row: PulledStock) in row.sku }, updated: { $0.updated_at }) { rows in
            for row in rows {
                if row.deleted_at != nil {
                    app.stock.untrack(row.sku)
                } else if app.stock[row.sku] != nil {
                    // Tracked here: this device's count moves by sales and moves; take the reorder point.
                    app.stock.setReorder(row.sku, reorderAt: row.reorder_at)
                } else {
                    app.stock.track(row.sku, count: row.count, reorderAt: row.reorder_at)
                }
            }
            app.saveStock()
            return rows.count
        }
        app.reloadCatalog()
    }

    // MARK: - Photos

    /// Taught products' photos: each new local one goes up; a product with none here comes down (checked at most daily),
    /// and the gallery re-embeds it on this device (FeaturePrint vectors can differ between device models, so they
    /// never sync).
    private func syncPhotos(_ client: SupabaseClient, _ shop: UUID, _ app: AppModel, generation: Int) async throws {
        let bucket = client.storage.from("product-photos")
        var uploaded = Set(defaults.stringArray(forKey: "sync.photos") ?? [])
        var checked = defaults.dictionary(forKey: "sync.photosChecked") as? [String: Date] ?? [:]
        defer {
            defaults.set(Array(uploaded), forKey: "sync.photos")
            defaults.set(checked, forKey: "sync.photosChecked")
        }
        let prefix = shop.uuidString.lowercased()
        for product in app.catalog.products where Catalog.isQuickAdd(product.id) {
            try check(generation)
            let local = CropStore.photos(for: product.id)
            let folder = "\(prefix)/\(product.id)"
            if local.isEmpty {
                if let last = checked[product.id], last > .now.addingTimeInterval(-86_400) { continue }
                checked[product.id] = .now
                let files = try await bucket.list(path: folder)
                var got = false
                for file in files {
                    let name = URL(fileURLWithPath: file.name).lastPathComponent   // never a path out of Crops/<sku>
                    guard name.hasSuffix(".jpg"), !name.hasPrefix(".") else { continue }
                    let data = try await bucket.download(path: "\(folder)/\(name)")
                    CropStore.write(data, to: "Crops/\(product.id)/\(name)")
                    uploaded.insert("\(folder)/\(name)")
                    got = true
                }
                if got {
                    let gallery = app.gallery, sku = product.id
                    await Task.detached(priority: .utility) { gallery.rebuild(sku) }.value
                }
            } else {
                for url in local {
                    let path = "\(folder)/\(url.lastPathComponent)"
                    guard !uploaded.contains(path) else { continue }
                    try await bucket.upload(path, data: try Data(contentsOf: url),
                                            options: FileOptions(contentType: "image/jpeg", upsert: true))
                    uploaded.insert(path)
                }
            }
        }
    }

    // MARK: - Training photos (opt-in)

    /// Sends waiting training photos on Wi-Fi, at most `TrainingSamples.dailyLimit` a day. The server refuses them
    /// without this shop's consent row, so a photo can't go up for a shop that didn't agree.
    private func sendTraining(_ client: SupabaseClient, _ shop: UUID, generation: Int) async throws {
        guard TrainingSamples.isOn, TrainingSamples.onWiFi else { return }
        let bucket = client.storage.from("training-frames")
        let prefix = shop.uuidString.lowercased()
        for jpg in TrainingSamples.waiting().prefix(TrainingSamples.sendableToday) {
            try check(generation)
            guard TrainingSamples.isOn else { return }   // turned off mid-way: send nothing more
            let json = jpg.deletingPathExtension().appendingPathExtension("json")
            let name = jpg.deletingPathExtension().lastPathComponent
            // No overwriting (there's no update policy): a file already up from an interrupted try counts as sent.
            for (path, file, type) in [("\(prefix)/\(name).json", json, "application/json"), ("\(prefix)/\(name).jpg", jpg, "image/jpeg")] {
                do {
                    try await bucket.upload(path, data: try Data(contentsOf: file), options: FileOptions(contentType: type, upsert: false))
                } catch where "\(error)".contains("409") || "\(error)".localizedCaseInsensitiveContains("already exists")
                                || "\(error)".localizedCaseInsensitiveContains("Duplicate") {
                    continue
                }
            }
            try? FileManager.default.removeItem(at: jpg)
            try? FileManager.default.removeItem(at: json)
            TrainingSamples.countSent()
        }
    }

    /// Opt in or out on the server. Out also deletes every training photo this shop sent; returns how many.
    func setTrainingConsent(_ on: Bool) async throws -> Int {
        guard let client = Cloud.client else { throw CocoaError(.featureUnsupported) }
        let shop = try await shopID(client)
        struct Consent: Encodable {
            let shop_id: UUID
            let policy_version: String
            let withdrawing: Bool
        }
        // The times are the server's (a trigger sets granted_at / withdrawn_at), not this device's clock.
        if on {
            try await client.from("training_consent")
                .upsert(Consent(shop_id: shop, policy_version: TrainingSamples.policyVersion, withdrawing: false))
                .execute()
            return 0
        }
        try await client.from("training_consent")
            .upsert(Consent(shop_id: shop, policy_version: TrainingSamples.policyVersion, withdrawing: true))
            .execute()
        let bucket = client.storage.from("training-frames")
        let prefix = shop.uuidString.lowercased()
        var deleted = 0
        // Twice: an upload that was already past the server's check when consent was withdrawn lands after the first.
        for pass in 0..<2 {
            if pass == 1 { try await Task.sleep(for: .seconds(2)) }
            while true {
                let files = try await bucket.list(path: prefix, options: SearchOptions(limit: 1000))
                let paths = files.map { "\(prefix)/\($0.name)" }
                guard !paths.isEmpty else { break }
                let removed = try await bucket.remove(paths: paths)
                deleted += removed.count
                if removed.isEmpty || files.count < 1000 { break }   // nothing removed: don't spin
            }
        }
        return deleted / 2   // a photo and its labels
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
