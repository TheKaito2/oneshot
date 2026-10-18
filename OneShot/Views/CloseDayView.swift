import SwiftData
import SwiftUI

/// End of day (Odoo's closing control, OSPOS's cash up): count the drawer, see over or short, keep the record.
struct CloseDayView: View {
    @AppStorage("cashFloat") private var floatText = "0"
    @AppStorage(SettingsKey.shopName) private var shopName = ""
    @State private var countedText = ""
    @State private var closed: DayClose?
    @Environment(\.dismiss) private var dismiss

    @Environment(\.modelContext) private var context
    /// Only today's rows come out of the store.
    @Query private var today: [SaleRecord]

    init() {
        let start = Calendar.current.startOfDay(for: .now)
        _today = Query(filter: #Predicate<SaleRecord> { $0.date >= start }, sort: \.date)
    }

    private var summary: DaySummary { DaySummary.of(today.map(\.sale)) }

    private var float: Decimal { Decimal(string: floatText) ?? 0 }
    private var counted: Decimal? { Decimal(string: countedText.trimmingCharacters(in: .whitespaces)) }
    private var expected: Decimal { float + summary.cash }

    var body: some View {
        NavigationStack {
            Form {
                Section("Today") {
                    LabeledContent("Sales", value: "\(summary.sales)")
                    if summary.refunds > 0 { LabeledContent("Refunds", value: "\(summary.refunds)") }
                    LabeledContent("Items", value: "\(summary.items)")
                    LabeledContent("Revenue", value: summary.revenue.baht)
                    LabeledContent("Cash", value: summary.cash.baht)
                    LabeledContent("PromptPay", value: (summary.revenue - summary.cash).baht)
                }
                .frostedRows()
                Section("Cash drawer") {
                    LabeledContent("Float at opening") {
                        TextField("0", text: $floatText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Expected in drawer", value: expected.baht)
                    LabeledContent("Counted cash") {
                        TextField("Count the drawer", text: $countedText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if let counted {
                        differenceRow(counted - expected)
                    }
                }
                .frostedRows()
                if let closed {
                    Section("Day closed") {
                        Label("Saved \(closed.date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        ShareLink(item: report(closed)) { Label("Share the day report", systemImage: "square.and.arrow.up") }
                    }
                    .frostedRows()
                } else {
                    Section {
                        Button("Close the day", systemImage: "moon.stars.fill") { close() }
                            .disabled(counted == nil)
                    }
                    .frostedRows()
                }
            }
            .gridList()
            .navigationTitle("Close the day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func differenceRow(_ difference: Decimal) -> some View {
        LabeledContent {
            Text(difference == 0 ? "Even" : (difference > 0 ? "Over \(difference.baht)" : "Short \((-difference).baht)"))
                .bold()
                .foregroundStyle(difference == 0 ? .green : (difference > 0 ? .orange : .red))
        } label: {
            Text("Difference")
        }
    }

    private func close() {
        guard let counted else { return }
        let day = DayClose(date: .now, float: float, cashSales: summary.cash, counted: counted,
                           sales: summary.sales, revenue: summary.revenue)
        do {
            try DayCloseLog.save(day, in: context)
            closed = day
        } catch {
            print("day close not saved: \(error)")
        }
    }

    /// The Z report as text, for LINE or Notes.
    private func report(_ day: DayClose) -> String {
        let difference = day.difference == 0 ? String(localized: "even")
            : (day.difference > 0 ? String(localized: "over \(day.difference.baht)") : String(localized: "short \((-day.difference).baht)"))
        return """
        OneShot · \(shopName.isEmpty ? String(localized: "Your shop") : shopName) · \(day.date.formatted(date: .abbreviated, time: .shortened))
        \(String(localized: "Sales")) \(day.sales) · \(String(localized: "Revenue")) \(day.revenue.baht)
        \(String(localized: "Cash")) \(summary.cash.baht) · \(String(localized: "PromptPay")) \((summary.revenue - summary.cash).baht)
        \(String(localized: "Drawer: expected")) \(day.expected.baht), \(String(localized: "counted")) \(day.counted.baht) (\(difference))
        """
    }
}
