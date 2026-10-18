import Foundation
import Testing
@testable import OneShot

struct StockTests {
    private let now = Date(timeIntervalSince1970: 1_792_300_000)

    private func sale(_ sku: String, _ qty: Int, daysAgo: Double = 0) -> Sale {
        Sale(id: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400),
             lines: [SaleLine(sku: sku, name: sku, quantity: qty, amount: Decimal(qty * 20))], total: Decimal(qty * 20), method: .cash)
    }

    @Test func salesTakeStockAndRefundsPutItBack() {
        var stock = StockBook(levels: [:])
        stock.set("lays", count: 10, reorderAt: 4)
        let paid = sale("lays", 7)
        stock.apply(paid)
        #expect(stock["lays"]?.count == 3)
        #expect(stock.low.map(\.sku) == ["lays"])
        stock.apply(SalesLog.reversal(of: paid, id: paid.id!, at: now))
        #expect(stock["lays"]?.count == 10)
        #expect(stock.low.isEmpty)
    }

    @Test func untrackedProductsAreIgnoredAndNeverNegative() {
        var stock = StockBook(levels: [:])
        stock.apply(sale("mars", 3))
        #expect(stock["mars"] == nil)
        stock.set("kitkat", count: 1, reorderAt: 0)
        stock.apply(sale("kitkat", 5))
        #expect(stock["kitkat"]?.count == 0)
        stock.receive("kitkat", 12)
        #expect(stock["kitkat"]?.count == 12)
    }

    @Test func restockPaceFromThisWeek() {
        let sales = [sale("lays", 7, daysAgo: 1), sale("lays", 7, daysAgo: 3), sale("lays", 10, daysAgo: 20)]
        let rate = Restock.dailyRate("lays", sales: sales, now: now)
        #expect(rate == 2)   // 14 in the last 7 days; the 20-day-old sale is outside the window
        #expect(Restock.daysLeft(StockLevel(count: 3), rate: rate) == 1.5)
        #expect(Restock.daysLeft(StockLevel(count: 3), rate: 0) == nil)
    }
}
