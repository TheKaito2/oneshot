import Charts
import SwiftUI

// The full views behind a dashboard card's ⤢, after Apple Health and Stocks: the chart big, a finger on it reads the
// exact value, and every row underneath with nothing cut off.

/// Net sales over time: scrub for one hour's or day's takings against the period before.
struct TrendDetail: View {
    let report: Report
    let before: Report
    let bucket: Calendar.Component
    let shift: TimeInterval
    @State private var selected: Date?

    private var picked: Report.Bar? {
        guard let selected else { return nil }
        return report.bars.min { abs($0.start.timeIntervalSince(selected)) < abs($1.start.timeIntervalSince(selected)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let picked {
                Text(picked.net.baht).font(.seed(size: 34, .extraBold, relativeTo: .largeTitle)).foregroundStyle(Brand.ink)
                label(picked.start).font(.seed(.subheadline)).foregroundStyle(Brand.muted)
            } else {
                Text(report.net.baht).font(.seed(size: 34, .extraBold, relativeTo: .largeTitle)).foregroundStyle(Brand.ink)
                Text("Total · touch the chart for one \(bucket == .hour ? String(localized: "hour") : String(localized: "day"))")
                    .font(.seed(.subheadline)).foregroundStyle(Brand.muted)
            }
        }
        .contentTransition(.numericText())
        HStack(spacing: 16) { TrendLegend() }
        Chart {
            ForEach(before.bars) { bar in
                LineMark(x: .value("Time", bar.start.addingTimeInterval(shift), unit: bucket),
                         y: .value("Baht", bar.net.double), series: .value("Series", "before"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Brand.muted)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
            }
            ForEach(report.bars) { bar in
                LineMark(x: .value("Time", bar.start, unit: bucket), y: .value("Baht", bar.net.double), series: .value("Series", "now"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Brand.accent)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if let picked {
                RuleMark(x: .value("Time", picked.start, unit: bucket)).foregroundStyle(Brand.ink.opacity(0.25))
                PointMark(x: .value("Time", picked.start, unit: bucket), y: .value("Baht", picked.net.double))
                    .foregroundStyle(Brand.accent).symbolSize(90)
            }
        }
        .chartXSelection(value: $selected)
        .bahtAxes(time: bucket, every: bucket == .hour ? 3 : max(1, (report.bars.count + 6) / 7))
        .frame(height: 320)
        .card(padding: 20)
        VStack(spacing: 0) {
            ForEach(Array(report.bars.enumerated().reversed()), id: \.element.id) { index, bar in
                HStack {
                    label(bar.start).foregroundStyle(Brand.ink)
                    Spacer()
                    if before.bars.indices.contains(index) {
                        Text(before.bars[index].net.baht).foregroundStyle(Brand.muted).frame(minWidth: 70, alignment: .trailing)
                    }
                    Text(bar.net.baht).font(.seed(.callout, .bold)).foregroundStyle(Brand.ink).frame(minWidth: 80, alignment: .trailing)
                }
                .font(.seed(.callout))
                .padding(.vertical, 10)
                Divider()
            }
        }
        .card(padding: 16)
    }

    private func label(_ date: Date) -> Text {
        bucket == .hour ? Text(date, format: .dateTime.hour().minute()) : Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Every product sold, by money in, with full names: what Top products and Sales by item cut short.
struct ItemsDetail: View {
    let report: Report
    @State private var byUnits = false

    var body: some View {
        let items = report.items.sorted { byUnits ? $0.sold > $1.sold : $0.net > $1.net }
        let best = max(items.map { byUnits ? Double($0.sold) : $0.net.double }.max() ?? 1, 1)
        Picker("Sort", selection: $byUnits) {
            Text("By money").tag(false)
            Text("By units").tag(true)
        }
        .pickerStyle(.segmented)
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.seed(.callout, .bold)).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Text(item.net.baht).font(.seed(.callout, .bold)).foregroundStyle(Brand.ink)
                    }
                    Capsule().fill(Brand.series(index))
                        .frame(width: max(6, 220 * (byUnits ? Double(item.sold) : item.net.double) / best), height: 6)
                    HStack(spacing: 12) {
                        Text("^[\(item.sold) sold](inflect: true)")
                        if item.refunded > 0 { Text("\(item.refunded) refunded").foregroundStyle(Brand.negative) }
                        if report.net > 0 { Text((item.net.double / report.net.double).formatted(.percent.precision(.fractionLength(0)))) }
                        if let profit = item.profit { Text("Profit \(profit.baht)") }
                    }
                    .font(.seed(.caption))
                    .foregroundStyle(Brand.muted)
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
        .card(padding: 16)
    }
}

/// Each shelf group, then the products inside it.
struct CategoryDetail: View {
    let report: Report

    var body: some View {
        Chart {
            ForEach(Array(report.categories.enumerated()), id: \.offset) { index, group in
                BarMark(x: .value("Category", String(localized: group.category.title)), y: .value("Baht", group.net.double), width: .ratio(0.55))
                    .foregroundStyle(Brand.series(index))
                    .cornerRadius(8)
                    .annotation(position: .top) {
                        Text(group.net.baht).font(.seed(.caption, .bold)).foregroundStyle(Brand.ink)
                    }
            }
        }
        .bahtAxes()
        .frame(height: 300)
        .card(padding: 20)
        ForEach(Array(report.categories.enumerated()), id: \.offset) { index, group in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(Brand.series(index)).frame(width: 10, height: 10)
                    Text(group.category.title).font(.seed(.headline)).foregroundStyle(Brand.ink)
                    Spacer()
                    Text(group.net.baht).font(.seed(.headline)).foregroundStyle(Brand.ink)
                }
                ForEach(report.items.filter { $0.category == group.category }) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).foregroundStyle(Brand.body).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Text("×\(item.sold)").foregroundStyle(Brand.muted)
                        Text(item.net.baht).foregroundStyle(Brand.ink).frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(.seed(.callout))
                }
            }
            .card(padding: 16)
        }
    }
}

/// Cash against PromptPay, with counts and average sale per method.
struct PaymentsDetail: View {
    let report: Report

    var body: some View {
        let slices = report.payments.filter { $0.net > 0 }
        let total = slices.map(\.net).reduce(0, +)
        PaymentsDonutCard.donut(slices, size: 220)
            .frame(maxWidth: .infinity)
            .card(padding: 20)
        VStack(spacing: 0) {
            ForEach(slices) { payment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(PaymentsDonutCard.color(payment.method)).frame(width: 10, height: 10)
                        Text(PaymentsDonutCard.name(payment.method)).font(.seed(.headline)).foregroundStyle(Brand.ink)
                        Spacer()
                        Text(payment.net.baht).font(.seed(.headline)).foregroundStyle(Brand.ink)
                    }
                    HStack(spacing: 12) {
                        Text("^[\(payment.sales) sale](inflect: true)")
                        if total > 0 { Text((payment.net.double / total.double).formatted(.percent.precision(.fractionLength(0)))) }
                        if payment.sales > 0 { Text("Average \((payment.net / Decimal(payment.sales)).baht)") }
                    }
                    .font(.seed(.caption))
                    .foregroundStyle(Brand.muted)
                    .padding(.leading, 18)
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
        .card(padding: 16)
    }
}

/// Every pair bought together, names in full.
struct PairsDetail: View {
    let report: Report

    var body: some View {
        VStack(spacing: 0) {
            ForEach(report.pairs) { pair in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.first).foregroundStyle(Brand.ink)
                        Text("+ \(pair.second)").foregroundStyle(Brand.body)
                    }
                    .font(.seed(.callout))
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("^[\(pair.baskets) basket](inflect: true)").font(.seed(.callout, .bold)).foregroundStyle(Brand.ink)
                        Text((Double(pair.baskets) / Double(max(report.sales, 1))).formatted(.percent.precision(.fractionLength(0))))
                            .font(.seed(.caption)).foregroundStyle(Brand.muted)
                    }
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
        .card(padding: 16)
    }
}
