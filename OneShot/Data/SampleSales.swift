import Foundation
import SwiftData

/// Two weeks of plausible books for presenting on a fresh install (Settings › Demo), so Home and Reports have something
/// to show. Only offered while the log is empty, so real sales never mix with made-up ones. Seeded, so every demo
/// shows the same shape of numbers.
@MainActor
enum SampleSales {
    /// Adds the sales up to `now` and returns how many.
    @discardableResult
    static func fill(catalog: Catalog, days: Int = 14, now: Date = .now, calendar: Calendar = .current,
                     in context: ModelContext) throws -> Int {
        guard !catalog.products.isEmpty else { return 0 }
        var rng = SplitMix64(seed: 2026)
        let today = calendar.startOfDay(for: now)
        var count = 0
        for back in (0..<days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            for _ in 0..<(14 + rng.below(12)) {
                // Open 08:00–20:00.
                let date = day.addingTimeInterval(TimeInterval(8 * 3600 + rng.below(12 * 3600)))
                guard date <= now else { continue }
                var quantities: [String: Int] = [:]
                for _ in 0..<(1 + rng.below(4)) {
                    quantities[catalog.products[rng.below(catalog.products.count)].id, default: 0] += 1
                }
                let lines = quantities.keys.sorted().compactMap { sku in
                    catalog[sku].map { BillLine(product: $0, quantity: quantities[sku] ?? 1) }
                }
                let total = lines.reduce(Decimal(0)) { $0 + $1.amount }
                let units = lines.reduce(0) { $0 + $1.quantity }
                let cash = rng.below(5) < 2
                let sale = Sale(id: UUID(), date: date, lines: lines.map {
                    SaleLine(sku: $0.product.id, name: $0.product.nameEN, quantity: $0.quantity, amount: $0.amount)
                }, total: total, method: cash ? .cash : .promptPay, received: cash ? Cash.suggestions(for: total).dropFirst().first : nil,
                    ringUp: 2 + Double(rng.below(40)) / 10, autoUnits: units - (rng.below(6) == 0 ? 1 : 0))
                context.insert(SaleRecord(sale))
                count += 1
            }
        }
        try SalesLog.saveOrRollBack(context)   // once: a save per sale froze the screen for ~270 of them
        return count
    }
}

/// A small seeded generator (SplitMix64), so the sample books come out the same every time.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<bound.
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}
