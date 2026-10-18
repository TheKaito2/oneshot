import Charts
import SwiftData
import SwiftUI

/// Reports laid out like Loyverse's and Square's: pick a period, see every number against the period before,
/// then the breakdowns (over time, by item, by category, by payment), stock that isn't selling and past closes.
/// Beyond them: what sells together, how fast OneShot rang it up, and a monthly statement for the bank.
struct ReportsView: View {
    let app: AppModel

    @Query(sort: \SaleRecord.date) private var records: [SaleRecord]
    @Query(sort: \CloseRecord.date, order: .reverse) private var closes: [CloseRecord]
    @State private var period: ReportPeriod = .today
    @State private var itemsCSV: URL?

    private var sales: [Sale] { records.map(\.sale) }

    /// Barcode pace for "time saved": 22 scans a minute, a staffed lane's rate (ONESHOT-MARKET-RESEARCH.md).
    private static let barcodeSecondsPerItem = 60.0 / 22

    var body: some View {
        let spans = period.spans()
        let report = Report(sales, in: spans.current, by: period.bucket, catalog: app.catalog)
        let before = Report(sales, in: spans.previous, by: period.bucket, catalog: app.catalog)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Period", selection: $period) {
                        ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    SectionMarker(index: 1, total: 4, title: "Summary", subtitle: period.comparison)
                    summary(report, before)
                    SectionMarker(index: 2, total: 4, title: "Over time")
                    TrendCard(title: period.bucket == .hour ? "Net sales by hour" : "Net sales by day", report: report, before: before,
                              bucket: period.bucket, shift: spans.current.start.timeIntervalSince(spans.previous.start))
                    SectionMarker(index: 3, total: 4, title: "Breakdown")
                    if report.items.isEmpty {
                        Label("No sales in this period.", systemImage: "chart.bar").font(.seed(.callout)).foregroundStyle(Brand.muted).card(padding: 20)
                    } else {
                        itemTable(report)
                        // Side by side when both fit, else stacked (sidebar docked, Split View).
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) {
                                CategoryBarsCard(report: report).frame(minWidth: 320)
                                PaymentsDonutCard(report: report).frame(minWidth: 360)
                            }
                            VStack(spacing: 20) {
                                CategoryBarsCard(report: report)
                                PaymentsDonutCard(report: report)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) {
                                together(report).frame(minWidth: 320)
                                speed(report).frame(minWidth: 320)
                            }
                            VStack(spacing: 20) {
                                together(report)
                                speed(report)
                            }
                        }
                    }
                    if period == .week || period == .month {
                        notSelling(report)
                    }
                    SectionMarker(index: 4, total: 4, title: "Records")
                    StatementCard(catalog: app.catalog, sales: sales)
                    if !closes.isEmpty {
                        closeHistory
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(GridBackground())
            .navigationTitle("Reports")
            .toolbar {
                if let itemsCSV {
                    ShareLink(item: itemsCSV) { Label("Export items CSV", systemImage: "square.and.arrow.up") }
                }
            }
            .task(id: "\(period)-\(records.count)") { itemsCSV = Self.writeCSV(report, period: period) }
        }
    }

    // MARK: - Summary

    private func summary(_ r: Report, _ before: Report) -> some View {
        KPIRows {
            KPITile(title: "Net sales", value: r.net.baht, symbol: "banknote", change: Report.change(r.net, from: before.net),
                    versus: period.versus, tint: Brand.accent)
            KPITile(title: "Gross sales", value: r.gross.baht, symbol: "cart", change: Report.change(r.gross, from: before.gross),
                    versus: period.versus, tint: Brand.sky)
            KPITile(title: "Refunds", value: r.refunds.baht, symbol: "arrow.uturn.backward",
                    change: Report.change(r.refunds, from: before.refunds), versus: period.versus, upIsGood: false, tint: Brand.mauve)
            profitTile(r, before)
            KPITile(title: "Sales", value: "\(r.sales)", symbol: "receipt", change: Report.change(Double(r.sales), from: Double(before.sales)),
                    versus: period.versus, tint: Brand.sky)
            KPITile(title: "Average sale", value: r.averageSale.baht, symbol: "basket",
                    change: Report.change(r.averageSale, from: before.averageSale), versus: period.versus, tint: Brand.accent)
            KPITile(title: "Items per sale", value: r.unitsPerSale.formatted(.number.precision(.fractionLength(1))), symbol: "square.stack.3d.up",
                    change: Report.change(r.unitsPerSale, from: before.unitsPerSale), versus: period.versus, tint: Brand.sand)
            KPITile(title: "Items sold", value: "\(r.units)", symbol: "shippingbox", change: Report.change(Double(r.units), from: Double(before.units)),
                    versus: period.versus, tint: Brand.sage)
        }
    }

    @ViewBuilder
    private func profitTile(_ r: Report, _ before: Report) -> some View {
        if let profit = r.profit {
            KPITile(title: "Gross profit", value: profit.baht, symbol: "chart.line.uptrend.xyaxis",
                    change: before.profit.flatMap { Report.change(profit, from: $0) }, versus: period.versus, tint: Brand.sage,
                    note: r.netWithoutCost > 0 ? "Leaves out \(r.netWithoutCost.baht) of sales with no cost yet" : nil)
        } else {
            Button { app.tab = .products } label: {
                KPITile(title: "Gross profit", value: "–", symbol: "chart.line.uptrend.xyaxis", tint: Brand.sage,
                        note: "Add what you pay for each product in Products to see profit.")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Breakdowns

    private func itemTable(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sales by item").font(.seed(.title3))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("Item")
                    Text("Sold").gridColumnAlignment(.trailing)
                    Text("Refunded").gridColumnAlignment(.trailing)
                    Text("Net").gridColumnAlignment(.trailing)
                    Text("Share").gridColumnAlignment(.trailing)
                    Text("Profit").gridColumnAlignment(.trailing)
                }
                .eyebrow()
                Divider()
                ForEach(r.items) { item in
                    GridRow {
                        HStack(spacing: 10) {
                            if let product = app.catalog[item.sku] {
                                ProductPhoto(product: product).frame(width: 32, height: 32).clipShape(.rect(cornerRadius: 6))
                            }
                            Text(item.name).foregroundStyle(Brand.ink).lineLimit(1)
                        }
                        Text(item.sold, format: .number).monospacedDigit()
                        Text(verbatim: item.refunded > 0 ? "\(item.refunded)" : "–").foregroundStyle(item.refunded > 0 ? Brand.negative : Brand.muted)
                        Text(item.net.baht).font(.seed(.callout, .bold)).foregroundStyle(Brand.ink)
                        Text(r.net > 0 ? (item.net.double / r.net.double).formatted(.percent.precision(.fractionLength(0))) : "–")
                            .monospacedDigit()
                            .foregroundStyle(Brand.muted)
                        Text(item.profit?.baht ?? "–").monospacedDigit().foregroundStyle(item.profit == nil ? .secondary : .primary)
                    }
                    .font(.seed(.callout))
                }
            }
        }
        .card(padding: 18)
    }

    private func together(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bought together", systemImage: "link").font(.seed(.title3))
            if r.pairs.isEmpty {
                Text("Two items show up here once they share a basket at least twice.").foregroundStyle(Brand.muted)
            }
            ForEach(r.pairs) { pair in
                HStack {
                    Text("\(pair.first) + \(pair.second)").lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text("\(pair.baskets) baskets").bold()
                    Text((Double(pair.baskets) / Double(max(r.sales, 1))).formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(Brand.muted)
                }
                .font(.seed(.subheadline))
            }
            if !r.pairs.isEmpty {
                Text("Shelve them side by side, or price them as a set.").font(.seed(.caption)).foregroundStyle(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    private func speed(_ r: Report) -> some View {
        let saved = r.speed.secondsSaved(at: Self.barcodeSecondsPerItem)
        return VStack(alignment: .leading, spacing: 12) {
            Label { Text("OneShot speed").foregroundStyle(Brand.ink) } icon: { Image(systemName: "bolt.fill").foregroundStyle(Brand.accent) }.font(.seed(.title3))
            if r.speed.checkouts.isEmpty {
                Text("Ring-up times start with sales made in this version.").foregroundStyle(Brand.muted)
            } else {
                LabeledContent("Average ring-up") {
                    Text("\(r.speed.averageSeconds.formatted(.number.precision(.fractionLength(1)))) s").bold()
                }
                LabeledContent("Named by the AI") {
                    Text(r.speed.autoShare.formatted(.percent.precision(.fractionLength(0)))).bold()
                }
                LabeledContent("Time saved vs barcodes") {
                    Text(Duration.seconds(saved).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))).bold()
                }
                Text("Against 22 barcode scans a minute, a staffed lane's pace.")
                    .font(.seed(.caption))
                    .foregroundStyle(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    /// OSPOS's "no sales" stock report: products that didn't sell this period, with what's on the shelf.
    private func notSelling(_ r: Report) -> some View {
        let sold = Set(r.items.filter { $0.sold > 0 }.map(\.sku))
        let idle = app.catalog.products.filter { !sold.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            Label("Didn't sell", systemImage: "tortoise").font(.seed(.title3))
            if idle.isEmpty {
                Text("Every product sold at least once.").foregroundStyle(Brand.muted)
            }
            ForEach(idle) { product in
                HStack(spacing: 12) {
                    ProductPhoto(product: product).frame(width: 32, height: 32).clipShape(.rect(cornerRadius: 6))
                    Text(product.name)
                    Spacer()
                    if let level = app.stock[product.id] {
                        Text("\(level.count) on the shelf").foregroundStyle(Brand.muted)
                    }
                }
                .font(.seed(.subheadline))
            }
        }
        .card(padding: 18)
    }

    /// Loyverse's shift history: every day closed, and whether the drawer matched.
    private var closeHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Closed days", systemImage: "moon.stars").font(.seed(.title3))
            ForEach(closes.prefix(7).map(\.close), id: \.date) { close in
                HStack {
                    Text(close.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    Spacer()
                    Text("Expected \(close.expected.baht) · counted \(close.counted.baht)").foregroundStyle(Brand.muted)
                    Text(close.difference == 0 ? "Even" : (close.difference > 0 ? "Over \(close.difference.baht)" : "Short \((-close.difference).baht)"))
                        .bold()
                        .foregroundStyle(close.difference == 0 ? Brand.positive : (close.difference > 0 ? Brand.warning : Brand.negative))
                        .frame(minWidth: 110, alignment: .trailing)
                }
                .font(.seed(.subheadline))
            }
        }
        .card(padding: 18)
    }

    /// Loyverse's "Sales by item" export: one row per product for the period.
    private static func writeCSV(_ r: Report, period: ReportPeriod) -> URL? {
        var rows = ["item,category,sold,refunded,net,cost,profit"]
        for item in r.items {
            let name = "\"" + item.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            rows.append([name, item.category.rawValue, "\(item.sold)", "\(item.refunded)", "\(item.net)",
                         item.cost.map { "\($0)" } ?? "", item.profit.map { "\($0)" } ?? ""].joined(separator: ","))
        }
        let url = URL.temporaryDirectory.appending(path: "OneShot items \(period.rawValue).csv")
        do {
            try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("items csv not written: \(error)")
            return nil
        }
    }
}
