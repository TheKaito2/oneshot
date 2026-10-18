import Foundation
import Testing
@testable import OneShot

struct SalesTests {
    private let day = Date(timeIntervalSince1970: 1_792_300_000)   // 18 Oct 2026, morning in Bangkok

    private func sale(_ lines: [(String, Int, String)], at date: Date) -> Sale {
        let saleLines = lines.map { SaleLine(sku: $0.0, name: $0.0, quantity: $0.1, amount: Decimal(string: $0.2)!) }
        return Sale(date: date, lines: saleLines, total: saleLines.reduce(0) { $0 + $1.amount })
    }

    @Test func summarisesOnlyTodayWithTopSellers() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let sales = [
            sale([("Lay's", 2, "64"), ("Pocky", 1, "19.9")], at: day),
            sale([("Lay's", 1, "32")], at: day.addingTimeInterval(3600)),
            sale([("Water", 5, "50")], at: day.addingTimeInterval(-86_400)),   // yesterday
        ]
        let summary = DaySummary.of(sales, on: day, calendar: calendar)
        #expect(summary.sales == 2)
        #expect(summary.items == 4)
        #expect(summary.revenue == Decimal(string: "115.9")!)
        #expect(summary.topSellers == [.init(name: "Lay's", quantity: 3), .init(name: "Pocky", quantity: 1)])
        #expect(summary.template.hasPrefix("Today: 2 sales, 4 items"))
        #expect(summary.template.hasSuffix("Best seller: Lay's (3)."))
    }

    @Test func splitsCashFromPromptPayAndBucketsByHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        var cashSale = sale([("Lay's", 1, "32")], at: day)
        cashSale.method = .cash
        let summary = DaySummary.of([cashSale, sale([("Pocky", 1, "19.9")], at: day)], on: day, calendar: calendar)
        #expect(summary.cash == 32)
        #expect(summary.revenue - summary.cash == Decimal(string: "19.9")!)
        #expect(summary.byHour.count == 1)
    }

    @Test func salesLoggedBeforeCashStillDecode() throws {
        let old = #"[{"date":0,"lines":[{"sku":"a","name":"A","quantity":1,"amount":20}],"total":20}]"#
        let sales = try JSONDecoder().decode([Sale].self, from: Data(old.utf8))
        #expect(sales.first?.method == nil)
    }

    @Test func emptyDaySaysSo() {
        #expect(DaySummary.of([]).template == "No sales yet today.")
    }
}

struct RefundAndCloseTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_300_000)

    private func sale(_ total: Decimal, qty: Int = 2, method: PaymentMethod = .cash, at date: Date) -> Sale {
        Sale(id: UUID(), date: date, lines: [SaleLine(sku: "lays", name: "Lay's", quantity: qty, amount: total)],
             total: total, method: method)
    }

    @Test func refundCancelsTheSaleInTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let paid = sale(40, at: t0)
        let refund = SalesLog.reversal(of: paid, id: paid.id!, at: t0.addingTimeInterval(60))
        #expect(refund.total == -40 && refund.lines[0].quantity == -2 && refund.refundOf == paid.id)
        let day = DaySummary.of([paid, refund], on: t0, calendar: calendar)
        #expect(day.sales == 1 && day.refunds == 1)
        #expect(day.revenue == 0 && day.items == 0 && day.cash == 0)
        #expect(day.topSellers.isEmpty)
    }

    @Test func csvQuotesNamesAndKeepsRefundLinks() {
        let paid = Sale(id: UUID(), date: t0, lines: [SaleLine(sku: "x", name: "Julie's \"Le-Mond\"", quantity: 1, amount: 12)],
                        total: 12, method: .promptPay)
        let csv = SalesLog.csv([paid])
        #expect(csv.contains("\"Julie's \"\"Le-Mond\"\"\""))
        #expect(csv.hasPrefix("\u{FEFF}date,sale,refund_of,method,sku,name,quantity,amount\n"))   // BOM: Excel reads Thai
    }

    @Test func dayCloseShowsOverAndShort() {
        let short = DayClose(date: t0, float: 500, cashSales: 1240, counted: 1720, sales: 23, revenue: 1890)
        #expect(short.expected == 1740 && short.difference == -20)
        let even = DayClose(date: t0, float: 0, cashSales: 90, counted: 90, sales: 2, revenue: 90)
        #expect(even.difference == 0)
    }

    @Test func refundPINIsFourDigitsKeptInTheKeychain() throws {
        #expect(RefundPIN.isValid("0427"))
        #expect(!RefundPIN.isValid("427") && !RefundPIN.isValid("04a7") && !RefundPIN.isValid("๐๔๒๗") && !RefundPIN.isValid("04271"))

        let account = "test-\(UUID())"   // never the shop's own PIN
        defer { try? RefundPIN.save(nil, account: account) }
        #expect(!RefundPIN.isSet(account: account))
        try RefundPIN.save("0427", account: account)
        #expect(RefundPIN.isSet(account: account))
        #expect(RefundPIN.matches("0427", account: account) && !RefundPIN.matches("0428", account: account))
        try RefundPIN.save(nil, account: account)
        #expect(!RefundPIN.isSet(account: account) && !RefundPIN.matches("0427", account: account))

        try RefundPIN.save("0427", account: account)
        UserDefaults.standard.removeObject(forKey: account)   // what a reinstall does: the Keychain item stays
        #expect(!RefundPIN.isSet(account: account))
    }
}
