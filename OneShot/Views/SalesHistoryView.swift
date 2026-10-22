import SwiftData
import SwiftUI

/// Every sale and refund, newest first, by day. Tap one for its receipt or to refund it. Export as CSV.
struct SalesHistoryView: View {
    let app: AppModel

    @Environment(\.modelContext) private var context
    @Query(sort: \SaleRecord.date) private var records: [SaleRecord]
    @State private var selected: Int?
    @State private var csvURL: URL?
    @State private var problem: String?
    @AppStorage(SettingsKey.shopName) private var shopName = ""

    /// Converted once per change and passed down: each row used to rebuild every Sale from the store (O(days ×
    /// sales²)), then every render did, so each tap on a sale waited for the whole history (22 Oct).
    @State private var sales: [Sale] = []

    var body: some View {
        let refundedIDs = Set(sales.compactMap(\.refundOf))
        let byDay = Dictionary(grouping: sales.indices) { Calendar.current.startOfDay(for: sales[$0].date) }
        List {
            if sales.isEmpty {
                Text("No sales yet.").foregroundStyle(Brand.muted)
            }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(byDay[day, default: []].reversed(), id: \.self) { index in
                        Button { selected = index } label: { row(sales[index], refundedIDs: refundedIDs) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
                }
                .frostedRows()
            }
        }
        .gridList()
        .onChange(of: "\(records.count)-\(records.last?.id.uuidString ?? "")", initial: true) { sales = records.map(\.sale) }
        .navigationTitle("Sales")
        .toolbar {
            if let csvURL {
                ShareLink(item: csvURL) { Label("Export CSV", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(item: Binding(get: { selected.map(IndexBox.init) }, set: { selected = $0?.id })) { box in
            if sales.indices.contains(box.id) {
                SaleDetail(sale: sales[box.id], refunded: sales[box.id].id.map(refundedIDs.contains) ?? false,
                           shopName: shopName, catalog: app.catalog, onRefund: { refund(sales[box.id]) })
            }
        }
        .task(id: sales.count) { writeCSV(sales) }
        .alert("Refund not saved", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func row(_ sale: Sale, refundedIDs: Set<UUID>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sale.isRefund ? "arrow.uturn.backward.circle.fill" : (sale.method == .cash ? "banknote" : "qrcode"))
                .foregroundStyle(sale.isRefund ? Brand.negative : Brand.accent)
                .frame(width: 28)
            Text(sale.date, style: .time).foregroundStyle(Brand.muted)
            Text(sale.lines.map { line in
                let name = app.catalog[line.sku]?.name ?? line.name
                return abs(line.quantity) > 1 ? "\(name) ×\(abs(line.quantity))" : name
            }.joined(separator: ", "))
                .lineLimit(1)
            Spacer()
            if let id = sale.id, refundedIDs.contains(id) {
                Text("Refunded").font(.seed(.caption, .bold)).foregroundStyle(Brand.negative)
            }
            Text(sale.total.baht).font(.seed(.body, .bold)).foregroundStyle(sale.isRefund ? Brand.negative : Brand.ink)
        }
        .contentShape(.rect)
    }

    private func writeCSV(_ sales: [Sale]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "OneShot sales.csv")
        do {
            try SalesLog.csv(sales).write(to: url, atomically: true, encoding: .utf8)
            csvURL = url
        } catch {
            Log.error("csv not written: \(error)")
            csvURL = nil
        }
    }

    private func refund(_ sale: Sale) {
        do {
            let refund = try SalesLog.refund(sale, in: context)
            app.applyToStock(refund)   // the items go back on the shelf
        } catch {
            problem = error.localizedDescription
        }
        selected = nil
    }

    private struct IndexBox: Identifiable { let id: Int }
}

private struct SaleDetail: View {
    let sale: Sale
    let refunded: Bool
    let shopName: String
    let catalog: Catalog
    let onRefund: () -> Void

    /// Rendered once: at 3× on every pass it re-ran on each PIN keystroke.
    @State private var image: Image?
    @State private var confirming = false
    @State private var askingPIN = false
    @State private var pinEntry = ""
    @State private var wrongPIN = false
    @Environment(\.dismiss) private var dismiss

    private var canRefund: Bool { sale.id != nil && !sale.isRefund && !refunded }

    private var howToRefund: Text {
        Text(sale.method == .cash
             ? "Give the customer the cash back. The items go back into stock."
             : "Send the money back by PromptPay. The items go back into stock.")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ReceiptView(sale: sale, shopName: shopName, catalog: catalog)
                        .clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                    if refunded {
                        Label("Refunded", systemImage: "arrow.uturn.backward.circle.fill").foregroundStyle(Brand.negative)
                    }
                    HStack {
                        if let image {
                            ShareLink(item: image, preview: SharePreview("Receipt", image: image)) {
                                Label("Share or print", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.glass)
                        }
                        if canRefund {
                            // With a PIN set (Settings), only someone who knows it can refund.
                            Button("Refund", systemImage: "arrow.uturn.backward", role: .destructive) {
                                if RefundPIN.isSet() { askingPIN = true } else { confirming = true }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .controlSize(.large)
                    if wrongPIN {
                        Label("Wrong PIN. Nothing was refunded.", systemImage: "lock.fill").foregroundStyle(Brand.negative)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .background(GridBackground())
            .task { image = ReceiptView.image(sale, shopName: shopName, catalog: catalog) }
            .navigationTitle(sale.isRefund ? Text("Refund") : Text("Receipt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Refund \(sale.total.baht)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Refund", role: .destructive, action: onRefund)
            } message: {
                howToRefund
            }
            .alert("Refund \(sale.total.baht)?", isPresented: $askingPIN) {
                SecureField("Refund PIN", text: $pinEntry).keyboardType(.numberPad)
                Button("Refund", role: .destructive) {
                    wrongPIN = !RefundPIN.matches(pinEntry)
                    pinEntry = ""
                    if !wrongPIN { onRefund() }
                }
                Button("Cancel", role: .cancel) { pinEntry = "" }
            } message: {
                howToRefund
            }
        }
    }
}
