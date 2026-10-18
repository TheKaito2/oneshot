import Foundation
import Testing
@testable import OneShot

struct ReportTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        calendar.firstWeekday = 2
        return calendar
    }

    private let calendar = Self.calendar
    /// Sunday 18 Oct 2026, 13:00 in Bangkok.
    private let now = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 13))!

    private let catalog = Catalog(products: [
        Product(id: "kitkat", nameEN: "KitKat", nameTH: "คิทแคท", price: 12, barcode: nil, category: .chocolate, cost: 9),
        Product(id: "lays", nameEN: "Lay's", nameTH: "เลย์", price: 20, barcode: nil, category: .chips),
        Product(id: "cola", nameEN: "Jolly Cola", nameTH: "จอลลี่ โคล่า", price: 10, barcode: nil, category: .candy, cost: 7),
    ])

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 18) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func sale(_ lines: [(String, Int)], at date: Date, method: PaymentMethod = .promptPay,
                      ringUp: Double? = nil, auto: Int? = nil) -> Sale {
        let saleLines = lines.map { SaleLine(sku: $0.0, name: $0.0, quantity: $0.1, amount: catalog[$0.0]!.price * Decimal($0.1)) }
        return Sale(id: UUID(), date: date, lines: saleLines, total: saleLines.reduce(0) { $0 + $1.amount },
                    method: method, ringUp: ringUp, autoUnits: auto)
    }

    private func report(_ sales: [Sale], _ period: ReportPeriod = .today) -> Report {
        Report(sales, in: period.spans(now: now, calendar: calendar).current, by: period.bucket,
               catalog: catalog, now: now, calendar: calendar)
    }

    @Test func todayIsComparedWithYesterdayUntilThisTime() {
        let (current, previous) = ReportPeriod.today.spans(now: now, calendar: calendar)
        #expect(current.start == at(0) && current.end == at(0, day: 19))
        #expect(previous.start == at(0, day: 17) && previous.end == at(13, day: 17))
    }

    @Test func monthSoFarIsComparedWithTheSameDaysOfLastMonth() {
        let (current, previous) = ReportPeriod.month.spans(now: now, calendar: calendar)
        let september1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        #expect(current.start == at(0, day: 1))
        #expect(previous.start == september1)
        #expect(previous.end == calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 13))!)
    }

    @Test func summaryNetsRefundsAndClaimsProfitOnlyWhereCostIsKnown() {
        let first = sale([("kitkat", 2), ("lays", 1)], at: at(9), method: .cash)          // ฿44
        let second = sale([("kitkat", 1), ("cola", 2)], at: at(10))                        // ฿32
        let refund = SalesLog.reversal(of: first, id: first.id!, at: at(11))               // −฿44 cash
        let r = report([first, second, refund, sale([("lays", 3)], at: at(9, day: 17))])  // yesterday's is out

        #expect(r.gross == 76 && r.refunds == 44 && r.net == 32)
        #expect(r.sales == 2 && r.refundCount == 1 && r.units == 3)
        #expect(r.averageSale == 16)
        // KitKat: ฿12 net, 1 unit kept at ฿9 → ฿3. Jolly Cola: ฿20, 2 at ฿7 → ฿6. Lay's has no cost: left out.
        #expect(r.profit == 9)
        #expect(r.items.map(\.sku) == ["cola", "kitkat", "lays"])
        let kitkat = r.items.first { $0.sku == "kitkat" }
        #expect(kitkat?.sold == 3 && kitkat?.refunded == 2)
        #expect(r.categories.map(\.category) == [.candy, .chocolate, .chips])
        #expect(r.payments.map(\.method) == [.promptPay, .cash])
        #expect(r.payments.map(\.sales) == [1, 1] && r.payments.map(\.net) == [32, 0])
    }

    @Test func pairsNeedAtLeastTwoBaskets() {
        let r = report([
            sale([("kitkat", 1), ("cola", 1)], at: at(9)),
            sale([("kitkat", 2), ("cola", 1), ("lays", 1)], at: at(10)),
            sale([("kitkat", 1), ("lays", 1)], at: at(11)),
        ])
        // Jolly Cola + Lay's met once: chance, not a pattern.
        #expect(r.pairs.map(\.id) == ["Jolly Cola+KitKat", "KitKat+Lay's"])
        #expect(r.pairs.map(\.baskets) == [2, 2])
    }

    @Test func speedComparesWithScanningEachBarcode() {
        let r = report([
            sale([("kitkat", 5)], at: at(9), ringUp: 4, auto: 4),
            sale([("lays", 2)], at: at(10), ringUp: 9, auto: 2),
            sale([("cola", 1)], at: at(11)),   // rung up before timing existed: not counted
        ])
        #expect(r.speed.checkouts.count == 2)
        #expect(r.speed.averageSeconds == 6.5)
        #expect(abs(r.speed.autoShare - 6.0 / 7.0) < 1e-9)
        // 5 items at 3 s = 15 s vs 4 s → 11 s saved; 2 items = 6 s vs 9 s → slower, counts as 0.
        #expect(r.speed.secondsSaved(at: 3) == 11)
    }

    @Test func barsRunHourlyUntilNow() {
        let r = report([sale([("kitkat", 1)], at: at(9, 15)), sale([("lays", 1)], at: at(12, 40))])
        #expect(r.bars.count == 13)   // 00:00 … 12:00
        #expect(r.bars.first { $0.start == at(9) }?.net == 12)
        #expect(r.bars.first { $0.start == at(12) }?.net == 20)
    }

    @Test func changeNeedsSomethingToCompareWith() {
        #expect(Report.change(Decimal(10), from: 0) == nil)
        #expect(Report.change(Decimal(15), from: 10) == 0.5)
        #expect(Report.change(3.0, from: 4.0) == -0.25)
    }
}
