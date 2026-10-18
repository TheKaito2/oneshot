import Foundation

/// The date ranges every POS report offers (Loyverse, Square, Shopify POS).
enum ReportPeriod: String, CaseIterable, Identifiable {
    case today, yesterday, week, month

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "This week"
        case .month: "This month"
        }
    }

    /// Short, under each number, so a tile's caption stays on one line.
    var versus: LocalizedStringResource {
        switch self {
        case .today: "vs yesterday"
        case .yesterday: "vs the day before"
        case .week: "vs last week"
        case .month: "vs last month"
        }
    }

    /// The exact comparison, said once under the section heading.
    var comparison: LocalizedStringResource {
        switch self {
        case .today: "Compared with yesterday up to this time."
        case .yesterday: "Compared with the day before."
        case .week: "Compared with the same days of last week."
        case .month: "Compared with the same days of last month."
        }
    }

    /// The span shown, and the span before it up to the same point: today so far against yesterday until this
    /// time, this month so far against the same days of last month. A running period never meets a full one.
    func spans(now: Date = .now, calendar: Calendar = .current) -> (current: DateInterval, previous: DateInterval) {
        let (unit, start): (Calendar.Component, Date) = switch self {
        case .today: (.day, calendar.startOfDay(for: now))
        case .yesterday: (.day, calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!)
        case .week: (.weekOfYear, calendar.dateInterval(of: .weekOfYear, for: now)!.start)
        case .month: (.month, calendar.dateInterval(of: .month, for: now)!.start)
        }
        let end = calendar.date(byAdding: unit, value: 1, to: start)!
        let previousStart = calendar.date(byAdding: unit, value: -1, to: start)!
        // By the calendar, not by elapsed seconds: on 31 March, "the same days of last month" ends on 28 February,
        // where adding 30 days to 1 February spilled into this month (19 Oct).
        let previousEnd = min(start, calendar.date(byAdding: unit, value: -1, to: min(now, end))!)
        return (DateInterval(start: start, end: end), DateInterval(start: previousStart, end: previousEnd))
    }

    /// Chart bars: hours for one day, days for longer.
    var bucket: Calendar.Component { self == .today || self == .yesterday ? .hour : .day }
}

/// One span's numbers in the shape of Loyverse's sales summary (gross, refunds, net, profit) plus the
/// breakdowns standard POS reports carry: by item, by category, by payment type, over time. On top:
/// what sells together, and how fast OneShot rang it up.
struct Report: Equatable {
    struct Item: Equatable, Identifiable {
        let sku: String
        let name: String
        let category: ProductCategory
        /// Units on paid bills, and units given back.
        var sold = 0, refunded = 0
        /// Money in, refunds out.
        var net: Decimal = 0
        /// What the units kept cost the shop; nil when the product has no cost yet.
        var cost: Decimal?

        var id: String { sku }
        var profit: Decimal? { cost.map { net - $0 } }
    }

    struct Group: Equatable, Identifiable {
        let category: ProductCategory
        var units = 0
        var net: Decimal = 0
        var id: ProductCategory { category }
    }

    struct Payment: Equatable, Identifiable {
        let method: PaymentMethod
        var sales = 0
        var net: Decimal = 0
        var id: PaymentMethod { method }
    }

    /// Two products in the same basket.
    struct Pair: Equatable, Identifiable {
        let first: String, second: String
        var baskets: Int
        var id: String { first + "+" + second }
    }

    struct Bar: Equatable, Identifiable {
        let start: Date
        var net: Decimal = 0
        var id: Date { start }
    }

    /// Checkouts rung up in OneShot (sales logged with a ring-up time).
    struct Speed: Equatable {
        struct Checkout: Equatable {
            let units: Int
            let auto: Int
            let seconds: Double
        }

        var checkouts: [Checkout] = []

        var averageSeconds: Double { checkouts.isEmpty ? 0 : checkouts.map(\.seconds).reduce(0, +) / Double(checkouts.count) }
        /// Share of units the AI named without a cashier pick or a hand-add.
        var autoShare: Double {
            let units = checkouts.map(\.units).reduce(0, +)
            return units == 0 ? 0 : Double(checkouts.map(\.auto).reduce(0, +)) / Double(units)
        }

        /// Time not spent scanning barcodes one by one at `secondsPerItem`; a checkout slower than that saves nothing.
        func secondsSaved(at secondsPerItem: Double) -> Double {
            checkouts.map { max(0, Double($0.units) * secondsPerItem - $0.seconds) }.reduce(0, +)
        }
    }

    /// Paid bills before refunds.
    var gross: Decimal = 0
    /// Money given back, as a positive amount.
    var refunds: Decimal = 0
    var net: Decimal { gross - refunds }
    var sales = 0
    var refundCount = 0
    /// Net of refunds.
    var units = 0
    /// Best-selling (by net) first.
    var items: [Item] = []
    var categories: [Group] = []
    var payments: [Payment] = []
    /// At most 5, most baskets first; a pair seen once is chance, so only pairs seen at least twice.
    var pairs: [Pair] = []
    var bars: [Bar] = []
    var speed = Speed()

    var averageSale: Decimal { sales > 0 ? net / Decimal(sales) : 0 }
    var unitsPerSale: Double { sales > 0 ? Double(units) / Double(sales) : 0 }
    /// Profit on the products that have a cost; nil when none do.
    var profit: Decimal? {
        let known = items.compactMap(\.profit)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Net sales of products without a cost: their profit is left out rather than guessed.
    var netWithoutCost: Decimal { items.filter { $0.cost == nil }.map(\.net).reduce(0, +) }

    init() {}

    init(_ all: [Sale], in span: DateInterval, by bucket: Calendar.Component = .day, catalog: Catalog,
         now: Date = .now, calendar: Calendar = .current) {
        let sales = all.filter { span.start <= $0.date && $0.date < span.end }
        var items: [String: Item] = [:], payments: [PaymentMethod: Payment] = [:], pairs: [String: Pair] = [:]
        var bars = Self.buckets(span, by: bucket, until: now, calendar: calendar).map { Bar(start: $0) }
        for sale in sales {
            if sale.isRefund {
                refunds -= sale.total
                refundCount += 1
            } else {
                gross += sale.total
                self.sales += 1
            }
            let method = sale.method ?? .promptPay
            payments[method, default: Payment(method: method)].net += sale.total
            if !sale.isRefund { payments[method]!.sales += 1 }
            if let index = bars.lastIndex(where: { $0.start <= sale.date }) { bars[index].net += sale.total }

            for line in sale.lines {
                let product = catalog[line.sku]
                var item = items[line.sku] ?? Item(sku: line.sku, name: product?.name ?? line.name,
                                                   category: product?.category ?? .other,
                                                   cost: product?.cost.map { _ in 0 })
                if line.quantity > 0 { item.sold += line.quantity } else { item.refunded -= line.quantity }
                item.net += line.amount
                if let unitCost = product?.cost { item.cost = (item.cost ?? 0) + unitCost * Decimal(line.quantity) }
                items[line.sku] = item
                units += line.quantity
            }

            guard !sale.isRefund else { continue }
            let basket = Set(sale.lines.filter { $0.quantity > 0 }.map(\.sku)).sorted()
            for (i, first) in basket.enumerated() {
                for second in basket[(i + 1)...] {
                    pairs[first + "+" + second, default: Pair(first: catalog[first]?.name ?? first,
                                                              second: catalog[second]?.name ?? second, baskets: 0)].baskets += 1
                }
            }
            if let seconds = sale.ringUp {
                let sold = sale.lines.map(\.quantity).filter { $0 > 0 }.reduce(0, +)
                speed.checkouts.append(.init(units: sold, auto: min(sale.autoUnits ?? 0, sold), seconds: seconds))
            }
        }
        self.items = items.values.sorted { $0.net != $1.net ? $0.net > $1.net : $0.name < $1.name }
        var groups: [ProductCategory: Group] = [:]
        for item in self.items {
            groups[item.category, default: Group(category: item.category)].units += item.sold - item.refunded
            groups[item.category]!.net += item.net
        }
        categories = groups.values.sorted { $0.net > $1.net }
        self.payments = payments.values.sorted { $0.net > $1.net }
        self.pairs = Array(pairs.values.filter { $0.baskets >= 2 }
            .sorted { $0.baskets != $1.baskets ? $0.baskets > $1.baskets : $0.id < $1.id }.prefix(5))
        self.bars = bars
    }

    /// Bar starts from the span's start until now (or the span's end, if that came first).
    static func buckets(_ span: DateInterval, by unit: Calendar.Component, until now: Date, calendar: Calendar) -> [Date] {
        var starts: [Date] = []
        var start = span.start
        while start < min(now, span.end) {
            starts.append(start)
            start = calendar.date(byAdding: unit, value: 1, to: start)!
        }
        return starts
    }

    /// Fractional change from `before` to `now`; nil when there was nothing before to compare with.
    static func change(_ now: Decimal, from before: Decimal) -> Double? {
        change(now.double, from: before.double)
    }

    /// Relative to the size of the base, so a better day after a refund-only day (negative net) reads as up.
    static func change(_ now: Double, from before: Double) -> Double? {
        before == 0 ? nil : (now - before) / abs(before)
    }
}
