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

    @MainActor
    static func load(from context: ModelContext) -> StockBook {
        do {
            let rows = try context.fetch(FetchDescriptor<StockRecord>())
            return StockBook(levels: Dictionary(rows.map { ($0.sku, $0.level) }, uniquingKeysWith: { first, _ in first }))
        } catch {
            print("stock not read: \(error)")
            return StockBook(levels: [:])
        }
    }

    /// Writes every level into the store, updating rows that exist.
    @MainActor
    func save(to context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<StockRecord>())
        let bySKU = Dictionary(rows.map { ($0.sku, $0) }, uniquingKeysWith: { first, _ in first })
        for (sku, level) in levels {
            if let row = bySKU[sku] {
                row.count = level.count
                row.reorderAt = level.reorderAt
            } else {
                context.insert(StockRecord(sku: sku, level: level))
            }
        }
        try context.save()
    }

    subscript(sku: String) -> StockLevel? { levels[sku] }

    /// Tracked products at or below their reorder point, emptiest first.
    var low: [(sku: String, level: StockLevel)] {
        levels.filter { $0.value.isLow }.map { ($0.key, $0.value) }.sorted { $0.level.count < $1.level.count }
    }

    mutating func set(_ sku: String, count: Int, reorderAt: Int) {
        levels[sku] = StockLevel(count: max(0, count), reorderAt: max(0, reorderAt))
    }

    mutating func receive(_ sku: String, _ quantity: Int) {
        var level = levels[sku] ?? StockLevel(count: 0)
        level.count += quantity
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
