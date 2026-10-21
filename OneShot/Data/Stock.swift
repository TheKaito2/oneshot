import Foundation
import SwiftData

struct StockLevel: Codable, Equatable {
    var count: Int
    /// At or below this, the product shows as low and the AI suggests reordering.
    var reorderAt: Int = 5

    var isLow: Bool { count <= reorderAt }
}

/// How many of each product are on the shelf. Products never counted aren't tracked (no badge, no alert).
struct StockBook: Equatable {
    private(set) var levels: [String: StockLevel]
    /// Products the owner stopped tracking since the last save: only these rows are deleted (a book that failed to
    /// load is empty, and saving it must not wipe every row).
    private var untracked: Set<String> = []
    /// Count changes that aren't sales (deliveries, recounts) since the last save, written as `StockMoveRecord`s so a
    /// synced device applies the same difference. Sales need none: each sale syncs and takes its own lines off.
    private var pendingMoves: [Move] = []

    private struct Move: Equatable {
        let sku: String
        let delta: Int
        let reason: String
    }

    init(levels: [String: StockLevel]) {
        self.levels = levels
    }

    @MainActor
    static func load(from context: ModelContext) -> StockBook {
        do {
            let rows = try context.fetch(FetchDescriptor<StockRecord>())
            return StockBook(levels: Dictionary(rows.map { ($0.sku, $0.level) }, uniquingKeysWith: { first, _ in first }))
        } catch {
            Log.error("stock not read: \(error)")
            return StockBook(levels: [:])
        }
    }

    /// Writes every level into the store, updating rows that exist and deleting untracked ones (with a tombstone
    /// for sync), plus the pending moves.
    @MainActor
    mutating func save(to context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<StockRecord>())
        for row in rows where untracked.contains(row.sku) && levels[row.sku] == nil {
            context.delete(row)
            context.insert(TombstoneRecord(kind: "stock", key: row.sku))
        }
        let bySKU = Dictionary(rows.filter { levels[$0.sku] != nil }.map { ($0.sku, $0) }, uniquingKeysWith: { first, _ in first })
        for (sku, level) in levels {
            if let row = bySKU[sku] {
                // The reorder point is a setting that syncs; the count travels as sales and moves.
                if row.reorderAt != level.reorderAt { row.updatedAt = .now }
                row.count = level.count
                row.reorderAt = level.reorderAt
            } else {
                context.insert(StockRecord(sku: sku, level: level))
            }
        }
        for move in pendingMoves { context.insert(StockMoveRecord(sku: move.sku, delta: move.delta, reason: move.reason)) }
        try context.save()
        pendingMoves = []
        untracked = []
    }

    subscript(sku: String) -> StockLevel? { levels[sku] }

    /// Tracked products at or below their reorder point, emptiest first.
    var low: [(sku: String, level: StockLevel)] {
        levels.filter { $0.value.isLow }.map { ($0.key, $0.value) }.sorted { $0.level.count < $1.level.count }
    }

    mutating func set(_ sku: String, count: Int, reorderAt: Int) {
        let delta = max(0, count) - (levels[sku]?.count ?? 0)
        if delta != 0 { pendingMoves.append(Move(sku: sku, delta: delta, reason: "count")) }
        levels[sku] = StockLevel(count: max(0, count), reorderAt: max(0, reorderAt))
        untracked.remove(sku)
    }

    /// Stops tracking a product: it leaves Running low and sales stop counting it down.
    mutating func untrack(_ sku: String) {
        levels[sku] = nil
        untracked.insert(sku)
    }

    mutating func receive(_ sku: String, _ quantity: Int) {
        var level = levels[sku] ?? StockLevel(count: 0)
        level.count += quantity
        levels[sku] = level
        pendingMoves.append(Move(sku: sku, delta: quantity, reason: "receive"))
    }

    /// Another device's delivery or recount, pulled by sync. Applied as the difference it made; no move is
    /// recorded here (it is already on the server). Untracked products are ignored, like sales.
    mutating func applyRemote(_ sku: String, delta: Int) {
        guard var level = levels[sku] else { return }
        level.count = max(0, level.count + delta)
        levels[sku] = level
    }

    /// A sale takes its lines off the shelf; a refund (negative lines) puts them back. Untracked products are ignored.
    mutating func apply(_ sale: Sale) {
        for line in sale.lines {
            guard var level = levels[line.sku] else { continue }
            level.count = max(0, level.count - line.quantity)
            levels[line.sku] = level
        }
    }
}

enum Restock {
    /// Units of `sku` sold per day over the last `days` days (refunds net out).
    static func dailyRate(_ sku: String, sales: [Sale], now: Date = .now, days: Int = 7) -> Double {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var sold = 0
        for sale in sales where sale.date >= since && sale.date <= now {
            for line in sale.lines where line.sku == sku { sold += line.quantity }
        }
        return max(0, Double(sold) / Double(days))
    }

    /// Days until the shelf is empty at the current rate; nil when it isn't selling.
    static func daysLeft(_ level: StockLevel, rate: Double) -> Double? {
        rate > 0 ? Double(level.count) / rate : nil
    }

    /// One line per low product, for the dashboard and the AI prompt: "Lay's Nori (S): 3 left, about 1 day".
    static func notes(stock: StockBook, sales: [Sale], catalog: Catalog, now: Date = .now) -> [String] {
        stock.low.map { item in
            let name = catalog[item.sku]?.nameEN ?? item.sku
            if let days = daysLeft(item.level, rate: dailyRate(item.sku, sales: sales, now: now)) {
                return "\(name): \(item.level.count) left, about \(Int(days.rounded(.up))) day(s) at this week's pace"
            }
            return "\(name): \(item.level.count) left"
        }
    }
}
