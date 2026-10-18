import SwiftUI
import TipKit

/// The current sale, always on screen beside the scan zone. Yellow items stay off the total until picked.
struct TicketPanel: View {
    @Bindable var app: AppModel

    @Environment(\.modelContext) private var context
    @State private var picking: Region?
    @State private var adding = false
    @State private var paying = false
    /// Charge tapped: ends the sale's ring-up time (Reports › OneShot speed).
    @State private var chargedAt: Date?
    @State private var toast: String?

    private var total: Decimal { app.scan?.total(catalog: app.catalog) ?? 0 }
    private var lines: [BillLine] { app.scan?.lines(catalog: app.catalog) ?? [] }
    private var unsure: [Region] { app.scan?.unsure ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Current sale").font(.seed(.title3)).foregroundStyle(Brand.ink)
                Spacer()
                Text(Date.now, style: .time).font(.seed(.subheadline)).foregroundStyle(Brand.muted)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            if app.scan == nil {
                emptyState
            } else {
                ScrollView { items.padding(.horizontal, 16) }
            }
            footer
        }
        .card(padding: 0)
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "brain")
                    .font(.seed(.callout))
                    .padding(12)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 170)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring, value: toast)
        .animation(.spring, value: lines)
        .sheet(item: $picking) { region in
            PickListView(region: region, catalog: app.catalog,
                         onPick: { sku in pick(region, as: sku) },
                         onNotAnItem: { remove(region) })
        }
        .sheet(isPresented: $adding) {
            PickListView(region: nil, catalog: app.catalog, onPick: { sku in
                app.scan?.manual.append(sku)
                adding = false
            })
        }
        .fullScreenCover(isPresented: $paying) {
            PayView(total: total, catalog: app.catalog, onPaid: { method, received in
                do {
                    let sale = try SalesLog.record(lines, total: total, method: method, received: received,
                                                   ringUp: chargedAt.flatMap { charged in app.scan.map { charged.timeIntervalSince($0.lockedAt) } },
                                                   autoUnits: app.scan?.autoUnits, in: context)
                    app.applyToStock(sale)
                    return sale
                } catch {
                    // The customer has paid; losing the log entry must not block the next customer.
                    print("sale not logged: \(error)")
                    return nil
                }
            }, onDone: {
                paying = false
                app.clearSale()
            })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "viewfinder")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(Brand.accent)
            Text("Ready for the next customer").font(.seed(.title3)).foregroundStyle(Brand.ink)
            Text("Hold the iPad over the items, then tap Ring up.")
                .font(.seed(.callout))
                .foregroundStyle(Brand.body)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var items: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if app.race.phase == .done, let summary = app.race.summary {
                Label(summary, systemImage: "flag.checkered")
                    .font(.seed(.headline))
                    .foregroundStyle(Brand.accent)
                    .card(padding: 12)
            }
            if !unsure.isEmpty {
                Text("Check these").eyebrow().padding(.top, 4)
                TipView(UnsureTip())
                ForEach(Array(unsure.enumerated()), id: \.element.id) { number, region in
                    Button { picking = region } label: { unsureRow(region, number: number + 1) }
                        .buttonStyle(.plain)
                }
            }
            if !lines.isEmpty {
                Text("Items").eyebrow().padding(.top, 4)
            }
            ForEach(lines) { line in
                lineRow(line)
            }
            Button("Add item", systemImage: "plus.circle.fill") { adding = true }
                .font(.seed(.headline))
                .padding(.vertical, 8)
        }
        .padding(.bottom, 12)
    }

    private func lineRow(_ line: BillLine) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: line.product)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.product.name).font(.seed(.headline)).foregroundStyle(Brand.ink).lineLimit(1)
                Text("\(line.product.price.baht) each").font(.seed(.subheadline)).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Remove one", systemImage: "minus.circle.fill") { app.scan?.removeOne(line.product.id) }
                .labelStyle(.iconOnly)
                .foregroundStyle(Brand.muted)
            Text("\(line.quantity)").font(.seed(.headline)).foregroundStyle(Brand.ink).frame(minWidth: 22)
            // A pack hidden under another one: the camera can't see it, the cashier can.
            Button("Add one", systemImage: "plus.circle.fill") { app.scan?.manual.append(line.product.id) }
                .labelStyle(.iconOnly)
            Text(line.amount.baht).font(.seed(.headline)).foregroundStyle(Brand.ink).frame(minWidth: 70, alignment: .trailing)
        }
        .font(.seed(.title3))
        .buttonStyle(.borderless)
        .padding(10)
        .background(Brand.card.opacity(0.7), in: .rect(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// The item as the camera saw it, or its learned photo when it was added by hand.
    @ViewBuilder
    private func thumbnail(for product: Product) -> some View {
        Group {
            if let crop = app.scan?.regions.first(where: { $0.verdict.sku == product.id })?.crop {
                Image(decorative: crop, scale: 1).resizable().scaledToFill()
            } else {
                ProductPhoto(product: product)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(.rect(cornerRadius: 10))
    }

    private func unsureRow(_ region: Region, number: Int) -> some View {
        HStack(spacing: 12) {
            Image(decorative: region.crop, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("? \(number) · tap to choose").font(.seed(.headline))
                if case .unsure(let candidates) = region.verdict, !candidates.isEmpty {
                    Text(candidates.compactMap { app.catalog[$0]?.name }.joined(separator: " / "))
                        .font(.seed(.caption))
                        .foregroundStyle(Brand.muted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Brand.muted)
        }
        .padding(10)
        .background(.yellow.opacity(0.18), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.yellow, lineWidth: 1.5))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(Brand.hairline).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total").eyebrow()
                    Text("^[\(lines.reduce(0) { $0 + $1.quantity }) item](inflect: true)").font(.seed(.caption)).foregroundStyle(Brand.muted)
                }
                Spacer()
                Text(total.baht)
                    .font(.seed(size: 40, .extraBold))
                    .foregroundStyle(Brand.ink)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: total)
            }
            if !unsure.isEmpty {
                Label("\(unsure.count) item(s) to check before paying", systemImage: "exclamationmark.triangle.fill")
                    .font(.seed(.callout))
                    .foregroundStyle(Brand.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Start over", role: .destructive) { app.clearSale() }
                    .buttonStyle(.glass)
                    .disabled(app.scan == nil)
                // Never a QR for a sale with unchecked items.
                Button {
                    chargedAt = .now
                    paying = true
                } label: {
                    Label("Charge \(total.baht)", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .primaryButton()
                // Not mid Scan more: a frame still on its way would change the total under the QR.
                .disabled(!unsure.isEmpty || total <= 0 || app.scanningMore)
            }
            .controlSize(.large)
        }
        .padding(16)
    }

    private func pick(_ region: Region, as sku: String) {
        guard let index = app.scan?.regions.firstIndex(where: { $0.id == region.id }) else { return }
        app.scan?.regions[index].verdict = .sure(sku: sku, by: .cashier)
        UnsureTip().invalidate(reason: .actionPerformed)
        CropStore.save(region.crop, sku: sku)
        // The pick teaches the gallery too, so the same item votes for itself next time.
        let crop = region.crop, gallery = app.gallery
        Task.detached(priority: .utility) {
            do {
                gallery.add([try Gallery.embed(crop)], to: sku)
            } catch {
                print("pick embed failed: \(error)")
            }
        }
        picking = nil
        showToast(String(localized: "Saved this photo to learn \(app.catalog[sku]?.name ?? sku)"))
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == text { toast = nil }
        }
    }

    private func remove(_ region: Region) {
        app.scan?.regions.removeAll { $0.id == region.id }
        picking = nil
    }
}
