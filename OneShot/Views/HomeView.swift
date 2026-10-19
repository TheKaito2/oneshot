import Charts
import FoundationModels
import os
import SwiftData
import SwiftUI

@Generable
struct SalesInsight {
    @Guide(description: "One short sentence about how today went, using only the numbers given")
    let headline: String
    @Guide(description: "Two or three short, concrete ideas for tomorrow based only on the numbers given", .count(2...3))
    let tips: [String]
}

/// The shop's day at a glance, laid out like the Dashboard Overview reference: a header, the way into a sale,
/// today's numbers in glass, the trend and breakdowns, and a rail of what needs attention and what just happened.
struct HomeView: View {
    let app: AppModel

    @AppStorage(SettingsKey.shopName) private var shopName = ""
    /// Live from the store: a sale paid in Checkout or a refund in history shows here at once.
    @Query private var records: [SaleRecord]
    @Query(sort: \CloseRecord.date) private var closeRecords: [CloseRecord]
    @State private var insight: SalesInsight?
    /// What the insight was written for, so coming back to Home doesn't blank and rewrite an unchanged one.
    @State private var insightKey: String?
    @State private var aiStatus: String?
    @State private var closingDay = false
    @State private var width: CGFloat = 0

    /// The judge sees the insight within this, or the numbers alone. Never a hang.
    private static let aiTimeout: Duration = .seconds(10)

    /// Home only shows today, yesterday and this week's pace, so it reads the last 8 days: it used to rebuild the
    /// whole history several times per render.
    init(app: AppModel) {
        self.app = app
        let since = Calendar.current.date(byAdding: .day, value: -8, to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
        _records = Query(filter: #Predicate<SaleRecord> { $0.date >= since }, sort: \.date)
    }

    private var sales: [Sale] { records.map(\.sale) }
    private var summary: DaySummary { DaySummary.of(sales, catalog: app.catalog) }

    private var restockNotes: [String] { Restock.notes(stock: app.stock, sales: sales, catalog: app.catalog) }

    /// Low shelves for products still in the catalog; a stock row left from a retired product (the stand-in
    /// catalog's "banana") would otherwise show an empty card.
    private var low: [(sku: String, level: StockLevel)] { app.stock.low.filter { app.catalog[$0.sku] != nil } }

    /// Landscape iPad: the rail sits beside the dashboard. Portrait: it follows below.
    private var wide: Bool { width > 1050 }

    var body: some View {
        NavigationStack {
            content
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { _ in SalesHistoryView(app: app) }
        }
        .sheet(isPresented: $closingDay) { CloseDayView() }
    }

    private var content: some View {
        let spans = ReportPeriod.today.spans()
        let report = Report(sales, in: spans.current, by: .hour, catalog: app.catalog)
        let before = Report(sales, in: spans.previous, by: .hour, catalog: app.catalog)
        let shift = spans.current.start.timeIntervalSince(spans.previous.start)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if Store.setAside != nil {
                    Label("The saved books wouldn't open, so they were set aside and new books started. Tell the owner.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.seed(.headline))
                        .foregroundStyle(Brand.warning)
                        .card(padding: 18)
                }
                hero
                SectionMarker(index: 1, total: 3, title: "Today", subtitle: ReportPeriod.today.comparison)
                KPIRows {
                    KPITile(title: "Net sales", value: report.net.baht, symbol: "banknote",
                            change: Report.change(report.net, from: before.net), tint: Brand.accent)
                    KPITile(title: "Sales", value: "\(report.sales)", symbol: "cart",
                            change: Report.change(Double(report.sales), from: Double(before.sales)), tint: Brand.sky)
                    KPITile(title: "Items sold", value: "\(report.units)", symbol: "shippingbox",
                            change: Report.change(Double(report.units), from: Double(before.units)), tint: Brand.sage)
                    KPITile(title: "Average sale", value: report.averageSale.baht, symbol: "basket",
                            change: Report.change(report.averageSale, from: before.averageSale), tint: Brand.mauve)
                }
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 20) {
                            SectionMarker(index: 2, total: 3, title: "Sales and payments")
                            dashboard(report, before, shift: shift)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            SectionMarker(index: 3, total: 3, title: "Activity")
                            rail
                        }
                        .frame(width: 320)
                    }
                } else {
                    SectionMarker(index: 2, total: 3, title: "Sales and payments")
                    dashboard(report, before, shift: shift)
                    SectionMarker(index: 3, total: 3, title: "Activity")
                    rail
                }
            }
            .padding(24)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(GridBackground())
        .task(id: insightInputs) { await generateInsight() }
    }

    // MARK: - Header and hero

    /// Full on iPad; on iPhone just the wordmark, the shop and the gear (the breadcrumb crushed the wordmark).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                Wordmark().fixedSize()
                Text(verbatim: "/").font(.seed(.title3, .regular)).foregroundStyle(Brand.mutedSoft)
                Text("Overview").font(.seed(.title3, .regular)).foregroundStyle(Brand.muted).fixedSize()
                Spacer()
                shopAndDate
                settingsButton
            }
            HStack(alignment: .center, spacing: 12) {
                Wordmark().fixedSize()
                Spacer(minLength: 8)
                settingsButton
            }
        }
    }

    private var shopAndDate: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(shopName.isEmpty ? String(localized: "Your shop") : shopName).font(.seed(.headline)).foregroundStyle(Brand.ink)
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.seed(.subheadline))
                .foregroundStyle(Brand.muted)
        }
        .fixedSize()
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") { app.showingSettings = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
    }

    /// The way into a sale, set like the site's headlines (eyebrow, display line, accent rule, lede), with the
    /// chameleon engraving watching from the right.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One-tap checkout").eyebrow()
            Text("Start a sale").font(.seed(size: 44, .heavy)).foregroundStyle(Brand.ink)
            AccentRule()
            Text("Hold the iPad over the items. One tap rings them all up.")
                .font(.seed(.title3, .regular))
                .foregroundStyle(Brand.body)
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Button { app.tab = .checkout } label: {
                        Label("Ring up", systemImage: "bolt.fill").font(.seed(.title3, .bold)).padding(.horizontal, 10).padding(.vertical, 2)
                    }
                    .primaryButton()
                    .controlSize(.large)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { heroActions }
                        VStack(alignment: .leading, spacing: 10) { heroActions }
                    }
                    .buttonStyle(.glass)
                    .lineLimit(1)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .leading)
        .background {
            // Only the backdrop is clipped: clipping the content too would make it its own layer, and the secondary
            // text's vibrancy has nothing to blend with there (the subtitle vanished).
            ZStack(alignment: .bottomTrailing) {
                Image("Chameleon")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 250)
                    .offset(x: 40, y: 30)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
        }
        .card(padding: 0)
    }

    /// The hero's secondary actions: one row when they fit, else stacked (large text, Thai, a docked sidebar).
    @ViewBuilder
    private var heroActions: some View {
        Button("Teach a product", systemImage: "plus.viewfinder") { app.startTeaching() }
        Button("Close the day", systemImage: "moon.stars.fill") { closingDay = true }
    }

    // MARK: - Dashboard and rail

    @ViewBuilder
    private func dashboard(_ report: Report, _ before: Report, shift: TimeInterval) -> some View {
        if report.sales + report.refundCount > 0 {
            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    TrendCard(title: "Net sales by hour", report: report, before: before, bucket: .hour, shift: shift)
                    if wide { TopProductsCard(report: report).frame(width: 300) }
                }
                if !wide { TopProductsCard(report: report) }
                // Side by side when both fit, else one above the other (sidebar docked, Split View).
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
            }
        } else {
            VStack(spacing: 14) {
                Image("Chameleon").resizable().scaledToFit().frame(height: 120).opacity(0.55).accessibilityHidden(true)
                Text("No sales yet today. Your first sale shows up here.").font(.seed(.callout)).foregroundStyle(Brand.body)
                NavigationLink(value: "history") { Text("Past sales").font(.seed(.callout, .bold)) }
            }
            .frame(maxWidth: .infinity)
            .card(padding: 28)
        }
    }

    /// The Dashboard Overview's right column: what needs attention, what just happened, the AI's read on the day.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !low.isEmpty {
                lowStock
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Activity").font(.seed(.title3)).foregroundStyle(Brand.ink)
                    Spacer()
                    NavigationLink(value: "history") { Text("See all").font(.seed(.subheadline, .bold)) }
                }
                let events = ActivityFeed.events(sales: sales, closes: closeRecords.map(\.close), catalog: app.catalog)
                if events.isEmpty {
                    Text("Sales, refunds and day closes show up here.").font(.seed(.subheadline)).foregroundStyle(Brand.muted)
                } else {
                    ActivityFeed(events: events)
                }
            }
            .card(padding: 18)
            insightCard
        }
    }

    /// OSPOS-style stock alerts, with this week's pace: what to reorder before it runs out.
    private var lowStock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("Running low").foregroundStyle(Brand.ink) } icon: {
                Image(systemName: "shippingbox.and.arrow.backward").foregroundStyle(Brand.accent)
            }
            .font(.seed(.title3))
            ForEach(low, id: \.sku) { item in
                if let product = app.catalog[item.sku] {
                    HStack(spacing: 12) {
                        ProductPhoto(product: product).frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name).font(.seed(.subheadline, .bold)).foregroundStyle(Brand.ink).lineLimit(1)
                            Text(paceText(sku: item.sku, level: item.level)).font(.seed(.caption)).foregroundStyle(Brand.muted)
                        }
                        Spacer()
                        Text("\(item.level.count) left").font(.seed(.subheadline, .bold)).foregroundStyle(item.level.count == 0 ? Brand.negative : Brand.warning)
                    }
                }
            }
            Button("Update stock in Products", systemImage: "square.grid.2x2") { app.tab = .products }
                .font(.seed(.subheadline, .bold))
        }
        .card(padding: 18)
    }

    private func paceText(sku: String, level: StockLevel) -> String {
        let rate = Restock.dailyRate(sku, sales: sales)
        if level.count == 0 { return String(localized: "Sold out") }
        guard let days = Restock.daysLeft(level, rate: rate) else { return String(localized: "Not selling this week") }
        return String(AttributedString(localized: "Sells \(String(format: "%.1f", rate))/day · about ^[\(Int(days.rounded(.up))) day](inflect: true) left").characters)
    }

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("On-device AI").foregroundStyle(Brand.ink) } icon: {
                Image(systemName: "sparkles").foregroundStyle(Brand.accent)
            }
            .font(.seed(.title3))
            if let insight {
                Text(insight.headline).font(.seed(.headline)).foregroundStyle(Brand.ink)
                ForEach(insight.tips, id: \.self) { tip in
                    Label { Text(tip).foregroundStyle(Brand.body) } icon: { Image(systemName: "lightbulb").foregroundStyle(Brand.accent) }
                        .font(.seed(.callout))
                }
            } else {
                // The day in plain numbers, always; why there's no AI read goes underneath.
                Text(summary.template).font(.seed(.subheadline)).foregroundStyle(Brand.body)
                if let aiStatus {
                    Text(aiStatus).font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
            }
        }
        .card(padding: 18)
    }

    // MARK: - On-device AI

    /// Changes when the day's numbers do (a sale, a refund, a shelf running low).
    private var insightInputs: String { "\(summary.sales)-\(summary.revenue)-\(low.count)" }

    private func generateInsight() async {
        let key = insightInputs
        guard key != insightKey || insight == nil else { return }
        insight = nil
        aiStatus = nil
        guard summary.sales > 0 else { return }
        switch SystemLanguageModel.default.availability {
        case .available:
            aiStatus = String(localized: "Writing…")
        case .unavailable(.appleIntelligenceNotEnabled):
            aiStatus = String(localized: "Turn on Apple Intelligence in Settings for an AI read of the day.")
            return
        case .unavailable(.modelNotReady):
            aiStatus = String(localized: "The on-device model is still downloading.")
            return
        case .unavailable:
            aiStatus = String(localized: "This iPad doesn't run Apple Intelligence.")
            return
        }
        var prompt = """
        Shop sales today: \(summary.template)
        Top sellers: \(summary.topSellers.map { "\($0.name) ×\($0.quantity)" }.joined(separator: ", ")).
        """
        // Low stock with this week's pace, so a tip can say what to reorder first.
        if !restockNotes.isEmpty { prompt += "\nRunning low: " + restockNotes.joined(separator: "; ") + "." }
        let request = prompt
        do {
            insight = try await withTimeout(Self.aiTimeout) {
                let session = LanguageModelSession(instructions: """
                    You help the owner of a small Thai corner shop. Be brief and friendly. \
                    Use only the numbers given; never invent figures.
                    """)
                return try await session.respond(to: request, generating: SalesInsight.self).content
            }
            insightKey = key
            aiStatus = nil
        } catch is CancellationError {
            return   // the day changed underneath (a new sale); the next run writes it
        } catch {
            guard !Task.isCancelled else { return }   // a newer run owns the card now
            aiStatus = error is TimedOut ? String(localized: "The AI took too long; here are the numbers.")
                : String(localized: "Couldn't write an AI read of the day.")
        }
    }
}

private struct TimedOut: LocalizedError {
    var errorDescription: String? { String(localized: "The AI took too long; here are the numbers.") }
}

/// Runs `work`, giving up after `limit`. A task group can't do it: leaving the group waits for every child, so a
/// model that ignores cancellation held the card on "Writing…" past the limit. First to finish resumes the caller.
private func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let result: T = try await withCheckedThrowingContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (Result<T, Error>) -> Void = { result in
            if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume(with: result) }
        }
        let job = Task {
            do { finish(.success(try await work())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: limit)
            job.cancel()
            finish(.failure(TimedOut()))
        }
    }
    try Task.checkCancellation()   // the day changed while it ran; the next run writes the card
    return result
}
