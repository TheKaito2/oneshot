import SwiftUI

/// One month of takings on an A4 page, for a loan officer or the owner's books: daily totals, refunds, and the
/// PromptPay share, money the bank can check against its own records. The Bank of Thailand finds small shops
/// lack the financial records formal credit asks for (Payment Directional Paper, 26 May 2026); OneShot already
/// keeps them, so this page just prints them.
struct StatementView: View {
    struct Day: Equatable, Identifiable {
        let date: Date
        let sales: Int
        let cash: Decimal
        let promptPay: Decimal
        var net: Decimal { cash + promptPay }
        var id: Date { date }
    }

    let month: DateInterval
    let sales: [Sale]
    let catalog: Catalog
    let shopName: String
    let promptPayID: String
    var now: Date = .now
    var calendar: Calendar = .current

    /// A row for each day of `month` with a sale or refund, up to now.
    static func days(_ sales: [Sale], in month: DateInterval, catalog: Catalog, now: Date, calendar: Calendar) -> [Day] {
        Report.buckets(month, by: .day, until: now, calendar: calendar).compactMap { start in
            let day = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
            let r = Report(sales, in: day, catalog: catalog, now: now, calendar: calendar)
            guard r.sales + r.refundCount > 0 else { return nil }
            return Day(date: start, sales: r.sales,
                       cash: r.payments.first { $0.method == .cash }?.net ?? 0,
                       promptPay: r.payments.first { $0.method == .promptPay }?.net ?? 0)
        }
    }

    var body: some View {
        let report = Report(sales, in: month, catalog: catalog, now: now, calendar: calendar)
        let days = Self.days(sales, in: month, catalog: catalog, now: now, calendar: calendar)
        let daysSoFar = Report.buckets(month, by: .day, until: now, calendar: calendar).count
        let promptPay = days.map(\.promptPay).reduce(0, +)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sales statement").font(.seed(.title2, .bold))
                    Text(shopName.isEmpty ? String(localized: "Your shop") : shopName).font(.seed(.headline))
                    Text(month.start, format: .dateTime.month(.wide).year()).foregroundStyle(Brand.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        LogoTile(size: 28)
                        Text(verbatim: "OneShot").font(.seed(.headline)).foregroundStyle(Brand.accent)
                    }
                    Text("Made \(now.formatted(date: .abbreviated, time: .shortened))").font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Net sales", report.net.baht, bold: true)
                row("Gross sales", report.gross.baht)
                row("Refunds", report.refunds.baht)
                row("Sales", "\(report.sales)")
                row("Days open", String(localized: "\(days.count) of \(daysSoFar)"))
                row("Average a day open", (days.isEmpty ? 0 : report.net / Decimal(days.count)).baht)
                row("PromptPay", "\(promptPay.baht) (\((report.net > 0 ? promptPay.double / report.net.double : 0).formatted(.percent.precision(.fractionLength(0)))))")
                row("Cash", (report.net - promptPay).baht)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                GridRow {
                    Text("Date")
                    Text("Sales").gridColumnAlignment(.trailing)
                    Text("Cash").gridColumnAlignment(.trailing)
                    Text("PromptPay").gridColumnAlignment(.trailing)
                    Text("Net").gridColumnAlignment(.trailing)
                }
                .font(.seed(.caption, .bold))
                .foregroundStyle(Brand.muted)
                ForEach(days) { day in
                    GridRow {
                        Text(day.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        Text(day.sales, format: .number)
                        Text(day.cash.baht)
                        Text(day.promptPay.baht)
                        Text(day.net.baht).bold()
                    }
                    .font(.seed(.caption))
                    .monospacedDigit()
                }
            }
            Divider()
            Text(promptPayID.isEmpty
                 ? "From the sales recorded by OneShot on the shop's device. PromptPay amounts can be matched with the shop's bank statement."
                 : "From the sales recorded by OneShot on the shop's device. PromptPay payments went to PromptPay ID \(promptPayID) and can be matched with the shop's bank statement.")
                .font(.seed(.caption))
                .foregroundStyle(Brand.muted)
        }
        .padding(36)
        .frame(width: 595, alignment: .topLeading)   // A4 width in points
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private func row(_ title: LocalizedStringKey, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(title)
            Text(value).monospacedDigit().bold(bold)
        }
        .font(.seed(.subheadline))
    }

    /// The page as a PDF to share, print or save; nil if it couldn't be written.
    @MainActor
    func pdf() -> URL? {
        // The local month in Gregorian years (a Thai iPad may run the Buddhist calendar); ISO 8601 formatting is UTC.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month], from: month.start)
        let url = URL.temporaryDirectory.appending(path: String(format: "OneShot statement %04d-%02d.pdf", parts.year ?? 0, parts.month ?? 0))
        var written = false
        ImageRenderer(content: self).render { size, draw in
            // An A4 page whatever the month's length (the page used to be as tall as the content), top-aligned, and
            // scaled down only when a long month would spill past the bottom.
            var box = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            let scale = min(1, box.width / size.width, box.height / size.height)
            pdf.beginPDFPage(nil)
            pdf.translateBy(x: (box.width - size.width * scale) / 2, y: box.height - size.height * scale)
            pdf.scaleBy(x: scale, y: scale)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            written = true
        }
        if !written { Log.error("statement pdf not written") }
        return written ? url : nil
    }
}

/// Reports' way to the statement: pick the month, preview it, share the PDF (Share includes Print and Files).
struct StatementCard: View {
    let catalog: Catalog
    let sales: [Sale]

    @AppStorage(SettingsKey.shopName) private var shopName = ""
    @AppStorage(SettingsKey.promptPayID) private var promptPayID = ""
    @State private var lastMonth = false
    @State private var pdf: URL?
    @State private var previewing = false
    @MainActor private static var made: [String: URL] = [:]
    private var pdfKey: String { "\(lastMonth)-\(sales.count)-\(sales.last?.id?.uuidString ?? "")-\(shopName)-\(promptPayID)" }
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The preview's width and the page's own height, to fit the page on a phone.
    @State private var available: CGFloat = 595 + 32
    @State private var pageHeight: CGFloat = 842

    private var month: DateInterval {
        let calendar = Calendar.current
        let this = calendar.dateInterval(of: .month, for: .now)!
        guard lastMonth else { return this }
        return calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -1, to: this.start)!)!
    }

    private var statement: StatementView {
        StatementView(month: month, sales: sales, catalog: catalog, shopName: shopName, promptPayID: promptPayID)
    }

    private var monthPicker: some View {
        Picker("Month", selection: $lastMonth) {
            Text("This month").tag(false)
            Text("Last month").tag(true)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Preview", systemImage: "doc.text.magnifyingglass") { previewing = true }
            .buttonStyle(.glass)
            .lineLimit(1)
        if let pdf {
            ShareLink(item: pdf) { Label("Share PDF", systemImage: "square.and.arrow.up").lineLimit(1) }
                .primaryButton()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Bank statement", icon: "building.columns",
                       info: "A month of takings on one page: daily totals, refunds, and the PromptPay share a bank can check against its own records. For a loan application or your own books.")
            // One row everywhere; on iPhone the buttons are icons (preview and share read without words).
            HStack(spacing: 10) {
                monthPicker.frame(maxWidth: 320)
                Spacer(minLength: 0)
                if sizeClass == .compact {
                    actions.labelStyle(.iconOnly)
                } else {
                    actions
                }
            }
        }
        .card(padding: 18)
        .task(id: pdfKey) {
            // Drawn once per month and set of sales, after the page has settled: drawing it on every visit to
            // Reports held up the tab switch (22 Oct).
            if let cached = Self.made[pdfKey] { pdf = cached; return }
            guard (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
            pdf = statement.pdf()
            Self.made[pdfKey] = pdf
        }
        .sheet(isPresented: $previewing) {
            NavigationStack {
                ScrollView {
                    // The A4 page is 595 pt wide: on iPhone it's shown scaled down whole, as a PDF viewer would.
                    let scale = min(1, (available - 32) / 595)
                    statement
                        .fixedSize(horizontal: false, vertical: true)   // its own height, not the scaled frame's
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: 595 * scale, height: pageHeight * scale, alignment: .topLeading)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
                .background(GridBackground())
                .navigationTitle("Statement")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { previewing = false } }
                    if let pdf {
                        ToolbarItem(placement: .primaryAction) { ShareLink(item: pdf) }
                    }
                }
            }
        }
    }
}
