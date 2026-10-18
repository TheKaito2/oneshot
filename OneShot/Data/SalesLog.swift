import Foundation
import SwiftData

struct SaleLine: Codable, Equatable {
    let sku: String
    let name: String
    let quantity: Int
    let amount: Decimal
}

struct Sale: Codable, Equatable {
    /// nil only in sales logged before refunds existed; those can't be refunded.
    var id: UUID?
    let date: Date
    let lines: [SaleLine]
    let total: Decimal
    /// nil in sales logged before cash existed; those were all PromptPay.
    var method: PaymentMethod?
    /// Cash handed over, for the receipt's change line.
    var received: Decimal?
    /// Set on a refund: the sale it reverses (Odoo's `refunded_order_id`). Refund lines and total are negative.
    var refundOf: UUID?
    /// Seconds from Ring up to the Charge tap: how long naming the items took, cashier fixes included.
    var ringUp: Double?
    /// Units the AI named on its own; the rest were cashier picks or added by hand.
    var autoUnits: Int?

    var isRefund: Bool { refundOf != nil }
    var change: Decimal? { received.map { $0 - total } }
}

/// Every paid bill and refund, kept in the SwiftData store (`SaleRecord`).
@MainActor
enum SalesLog {
    struct AlreadyRefunded: LocalizedError {
        var errorDescription: String? { String(localized: "This sale was already refunded.") }
    }

    @discardableResult
    static func record(_ lines: [BillLine], total: Decimal, method: PaymentMethod, received: Decimal? = nil,
                       ringUp: Double? = nil, autoUnits: Int? = nil,
                       at date: Date = .now, in context: ModelContext) throws -> Sale {
        let sale = Sale(id: UUID(), date: date, lines: lines.map {
            SaleLine(sku: $0.product.id, name: $0.product.nameEN, quantity: $0.quantity, amount: $0.amount)
        }, total: total, method: method, received: received, ringUp: ringUp, autoUnits: autoUnits)
        context.insert(SaleRecord(sale))
        try saveOrRollBack(context)
        return sale
    }

    /// A failed save is undone, not left pending: it used to be written by the next save, without its stock change.
    static func saveOrRollBack(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Logs the reverse of `sale` (same method, so cash refunds leave the drawer). One refund per sale.
    @discardableResult
    static func refund(_ sale: Sale, at date: Date = .now, in context: ModelContext) throws -> Sale {
        guard let id = sale.id, !sale.isRefund else { throw AlreadyRefunded() }
        let earlier = FetchDescriptor<SaleRecord>(predicate: #Predicate { $0.refundOf == id })
        guard try context.fetchCount(earlier) == 0 else { throw AlreadyRefunded() }
        let refund = reversal(of: sale, id: id, at: date)
        context.insert(SaleRecord(refund))
        try saveOrRollBack(context)
        return refund
    }

    nonisolated static func reversal(of sale: Sale, id: UUID, at date: Date) -> Sale {
        Sale(id: UUID(), date: date,
             lines: sale.lines.map { SaleLine(sku: $0.sku, name: $0.name, quantity: -$0.quantity, amount: -$0.amount) },
             total: -sale.total, method: sale.method, refundOf: id)
    }

    /// Oldest first.
    static func all(in context: ModelContext) -> [Sale] {
        do {
            return try context.fetch(FetchDescriptor<SaleRecord>(sortBy: [SortDescriptor(\.date)])).map(\.sale)
        } catch {
            print("sales not read: \(error)")
            return []
        }
    }

    /// One row per line, for a spreadsheet or an accountant.
    nonisolated static func csv(_ sales: [Sale]) -> String {
        // Local time with its offset ("2026-10-19T14:05:00+07:00"), as the app shows it; plain ISO 8601 wrote UTC.
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var rows = ["date,sale,refund_of,method,sku,name,quantity,amount"]
        for sale in sales {
            for line in sale.lines {
                let name = "\"" + line.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                rows.append([iso.string(from: sale.date), sale.id?.uuidString ?? "", sale.refundOf?.uuidString ?? "",
                             (sale.method ?? .promptPay).rawValue, line.sku, name, "\(line.quantity)", "\(line.amount)"]
                    .joined(separator: ","))
            }
        }
        // The byte-order mark makes Excel read the file as UTF-8, so Thai names don't come out garbled.
        return "\u{FEFF}" + rows.joined(separator: "\n") + "\n"
    }
}

struct DaySummary: Equatable {
    struct Seller: Equatable {
        let name: String
        let quantity: Int
    }

    /// Paid bills, not counting refunds.
    let sales: Int
    let refunds: Int
    /// Net of refunds.
    let items: Int
    let revenue: Decimal
    /// Net cash taken; the rest came in by PromptPay.
    let cash: Decimal
    /// Best first, at most 3.
    let topSellers: [Seller]
    /// Revenue per hour of the day (0–23), for the chart.
    let byHour: [Int: Decimal]

    var averageBasket: Decimal { sales > 0 ? revenue / Decimal(sales) : 0 }

    /// `catalog` names the best sellers in the app's language; the log keeps English.
    static func of(_ sales: [Sale], on day: Date = .now, calendar: Calendar = .current, catalog: Catalog? = nil) -> DaySummary {
        let today = sales.filter { calendar.isDate($0.date, inSameDayAs: day) }
        var quantities: [String: Int] = [:]
        for line in today.flatMap(\.lines) { quantities[catalog?[line.sku]?.name ?? line.name, default: 0] += line.quantity }
        let top = quantities.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map { Seller(name: $0.key, quantity: $0.value) }
        var byHour: [Int: Decimal] = [:]
        for sale in today { byHour[calendar.component(.hour, from: sale.date), default: 0] += sale.total }
        return DaySummary(sales: today.filter { !$0.isRefund }.count, refunds: today.filter(\.isRefund).count,
                          items: quantities.values.reduce(0, +),
                          revenue: today.reduce(0) { $0 + $1.total },
                          cash: today.filter { $0.method == .cash }.reduce(0) { $0 + $1.total },
                          topSellers: top, byHour: byHour)
    }

    /// The plain summary: always shown, and the whole summary on iPads without Apple Intelligence.
    var template: String {
        guard sales > 0 else { return String(localized: "No sales yet today.") }
        var text = String(localized: "Today: \(sales) sales, \(items) items, \(revenue.baht). Average sale \(averageBasket.baht).")
        if let best = topSellers.first { text += " " + String(localized: "Best seller: \(best.name) (\(best.quantity)).") }
        return text
    }
}

/// The end-of-day cash count (Odoo's session closing control, OSPOS's cash up).
struct DayClose: Codable, Equatable {
    let date: Date
    /// Cash in the drawer before the first sale.
    let float: Decimal
    /// Net cash taken today (sales minus cash refunds).
    let cashSales: Decimal
    let counted: Decimal
    let sales: Int
    let revenue: Decimal

    var expected: Decimal { float + cashSales }
    /// Positive: over. Negative: short.
    var difference: Decimal { counted - expected }
}

@MainActor
enum DayCloseLog {
    static func all(in context: ModelContext) -> [DayClose] {
        do {
            return try context.fetch(FetchDescriptor<CloseRecord>(sortBy: [SortDescriptor(\.date)])).map(\.close)
        } catch {
            print("closings not read: \(error)")
            return []
        }
    }

    static func save(_ close: DayClose, in context: ModelContext) throws {
        context.insert(CloseRecord(close))
        try context.save()
    }
}
