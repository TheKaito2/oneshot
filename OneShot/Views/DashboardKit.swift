import Charts
import SwiftUI

// The dashboard pieces Home and Reports share, laid out like the Dashboard Overview reference
// (KPI cards, a two-line trend, "by website" rows, "by device" bars, a donut) in kristpaulstudio.com's glass.
// Type follows Typography.swift: card title (Title 3 Bold) → value or rows (ink) → meta (muted).

/// One number on glass: an eyebrow label, the value, and how it moved against the period before.
struct KPITile: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String
    var change: Double?
    var versus: LocalizedStringResource = ReportPeriod.today.versus
    var upIsGood = true
    var tint: Color = Brand.accent
    /// Shown instead of the change, e.g. what a profit figure leaves out.
    var note: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(Brand.card, in: .circle)
                Text(title).eyebrow().lineLimit(1)
            }
            Text(value)
                .font(.seed(size: 30, .extraBold))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let note {
                Text(note).font(.seed(.caption)).foregroundStyle(Brand.accent).fixedSize(horizontal: false, vertical: true)
            } else {
                ChangeLabel(change: change, versus: versus, upIsGood: upIsGood)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .card(padding: 18)
    }
}

/// KPI tiles four across when each gets 200 pt, otherwise two (portrait, sidebar docked, Split View):
/// never three, which would strand the fourth tile on a row of its own.
struct KPIRows<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 1000

    var body: some View {
        let count = width >= 4 * 200 + 3 * 16 ? 4 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: count), spacing: 16) {
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    /// Chart axes in the type scale: Seed captions in muted ink on hairline grid lines, values as baht.
    /// A time axis labels its own bucket: hours by hour, days by date. Left to Charts, two days of data read
    /// "Oct 18 at 12 AM, Oct 18 at 12 PM…" (19 Oct).
    func bahtAxes(time bucket: Calendar.Component? = nil, every count: Int = 1) -> some View {
        chartXAxis {
            if let bucket {
                AxisMarks(values: .stride(by: bucket, count: count)) { _ in
                    AxisGridLine().foregroundStyle(Brand.hairline)
                    AxisValueLabel(format: bucket == .hour ? .dateTime.hour() : .dateTime.day().month(.abbreviated))
                        .font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
            } else {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Brand.hairline)
                    AxisValueLabel().font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Brand.hairline)
                AxisValueLabel {
                    if let baht = value.as(Double.self) { Text(Decimal(baht).baht).font(.seed(.caption)).foregroundStyle(Brand.muted) }
                }
            }
        }
    }
}

/// Net sales over the period, with the period before as a dashed line ("This year · Last year" in the reference).
struct TrendCard: View {
    let title: LocalizedStringKey
    let report: Report
    let before: Report
    let bucket: Calendar.Component
    /// How far to move the period before so it lines up under this one.
    let shift: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text(title).font(.seed(.title3)).foregroundStyle(Brand.ink)
                Spacer()
                legend("This period", color: Brand.accent)
                legend("Period before", color: Brand.muted)
            }
            // Monotone curves: Catmull-Rom overshot below ฿0 between a quiet day and a busy one (19 Oct).
            Chart {
                ForEach(before.bars) { bar in
                    LineMark(x: .value("Time", bar.start.addingTimeInterval(shift), unit: bucket),
                             y: .value("Baht", bar.net.double), series: .value("Series", "before"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Brand.muted)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
                }
                ForEach(report.bars) { bar in
                    AreaMark(x: .value("Time", bar.start, unit: bucket), yStart: .value("Baht", 0), yEnd: .value("Baht", bar.net.double))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Brand.accent.opacity(0.08))
                }
                ForEach(report.bars) { bar in
                    LineMark(x: .value("Time", bar.start, unit: bucket), y: .value("Baht", bar.net.double), series: .value("Series", "now"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Brand.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            // About seven labels whatever the period: every 3 hours today, every day this week, every 5 this month.
            .bahtAxes(time: bucket, every: bucket == .hour ? 3 : max(1, (report.bars.count + 6) / 7))
            .frame(height: 240)
        }
        .card(padding: 20)
    }

    private func legend(_ text: LocalizedStringKey, color: Color) -> some View {
        Label { Text(text) } icon: { Circle().fill(color).frame(width: 7, height: 7) }
            .font(.seed(.caption))
            .foregroundStyle(Brand.muted)
    }
}

/// The best sellers by money in, with a short bar each ("Traffic by Website" in the reference).
struct TopProductsCard: View {
    let report: Report
    var limit = 6

    var body: some View {
        let top = Array(report.items.filter { $0.net > 0 }.prefix(limit))
        let best = max(top.first?.net.double ?? 1, 1)
        VStack(alignment: .leading, spacing: 14) {
            Text("Top products").font(.seed(.title3)).foregroundStyle(Brand.ink)
            if top.isEmpty {
                Text("Nothing sold yet.").font(.seed(.subheadline)).foregroundStyle(Brand.muted)
            }
            ForEach(Array(top.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    Text(item.name).font(.seed(.callout)).foregroundStyle(Brand.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Capsule()
                        .fill(Brand.series(index))
                        .frame(width: max(6, 90 * item.net.double / best), height: 6)
                        .frame(width: 90, alignment: .leading)
                    Text(item.net.baht).font(.seed(.callout, .bold)).foregroundStyle(Brand.ink).frame(minWidth: 64, alignment: .trailing)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 20)
    }
}

/// Money in per shelf group, one colour each ("Traffic by Device" in the reference).
struct CategoryBarsCard: View {
    let report: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sales by category").font(.seed(.title3)).foregroundStyle(Brand.ink)
            Chart {
                ForEach(Array(report.categories.enumerated()), id: \.offset) { index, group in
                    BarMark(x: .value("Category", String(localized: group.category.title)), y: .value("Baht", group.net.double), width: .ratio(0.5))
                        .foregroundStyle(Brand.series(index))
                        .cornerRadius(8)
                }
            }
            .bahtAxes()
            .frame(height: 220)
        }
        .card(padding: 20)
    }
}

/// Cash against PromptPay as a donut with its legend ("Traffic by Location" in the reference).
struct PaymentsDonutCard: View {
    let report: Report

    var body: some View {
        let slices = report.payments.filter { $0.net > 0 }
        let total = slices.map(\.net).reduce(0, +)
        VStack(alignment: .leading, spacing: 16) {
            Text("Payments").font(.seed(.title3)).foregroundStyle(Brand.ink)
            HStack(spacing: 24) {
                ZStack {
                    Chart(slices) { payment in
                        SectorMark(angle: .value("Baht", payment.net.double), innerRadius: .ratio(0.62), angularInset: 2)
                            .cornerRadius(6)
                            .foregroundStyle(Self.color(payment.method))
                    }
                    VStack(spacing: 2) {
                        Text(total.baht).font(.seed(size: 20, .extraBold, relativeTo: .title3)).foregroundStyle(Brand.ink)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text("Net").eyebrow()
                    }
                    .padding(28)
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(slices) { payment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Circle().fill(Self.color(payment.method)).frame(width: 8, height: 8)
                                Text(payment.method == .cash ? "Cash" : "PromptPay").font(.seed(.callout)).foregroundStyle(Brand.ink)
                                Spacer()
                                Text(total > 0 ? (payment.net.double / total.double).formatted(.percent.precision(.fractionLength(0))) : "–")
                                    .font(.seed(.callout, .bold))
                                    .foregroundStyle(Brand.ink)
                            }
                            Text("^[\(payment.sales) sale](inflect: true) · \(payment.net.baht)").font(.seed(.caption)).foregroundStyle(Brand.muted).padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 20)
    }

    static func color(_ method: PaymentMethod) -> Color { method == .cash ? Brand.accent : Brand.sky }
}

/// What happened lately, newest first: sales, refunds and day closes ("Activities" in the reference).
struct ActivityFeed: View {
    struct Event: Identifiable {
        let id: String
        let date: Date
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
    }

    let events: [Event]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(event.tint)
                        .frame(width: 32, height: 32)
                        .background(Brand.card, in: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.seed(.subheadline, .bold)).foregroundStyle(Brand.ink)
                        Text(event.detail).font(.seed(.caption)).foregroundStyle(Brand.body).lineLimit(1)
                        Text(event.date, format: .relative(presentation: .named)).font(.seed(.caption)).foregroundStyle(Brand.muted)
                    }
                }
            }
        }
    }

    static func events(sales: [Sale], closes: [DayClose], catalog: Catalog? = nil, limit: Int = 6) -> [Event] {
        let fromSales = sales.suffix(limit).map { sale in
            let names = sale.lines.map { catalog?[$0.sku]?.name ?? $0.name }
            let detail = names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
            return sale.isRefund
                ? Event(id: "\(sale.date.timeIntervalSince1970)-r", date: sale.date, symbol: "arrow.uturn.backward", tint: Brand.negative,
                        title: String(localized: "Refund \((-sale.total).baht)"), detail: detail)
                : Event(id: "\(sale.date.timeIntervalSince1970)-s", date: sale.date, symbol: sale.method == .cash ? "banknote" : "qrcode",
                        tint: Brand.accent, title: String(localized: "Sale \(sale.total.baht)"), detail: detail)
        }
        let fromCloses = closes.suffix(limit).map { close in
            Event(id: "\(close.date.timeIntervalSince1970)-c", date: close.date, symbol: "moon.stars.fill", tint: Brand.mauve,
                  title: String(localized: "Day closed"),
                  detail: close.difference == 0 ? String(localized: "Even")
                      : (close.difference > 0 ? String(localized: "Over \(close.difference.baht)") : String(localized: "Short \((-close.difference).baht)")))
        }
        return Array((fromSales + fromCloses).sorted { $0.date > $1.date }.prefix(limit))
    }
}
