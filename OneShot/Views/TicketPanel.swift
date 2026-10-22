import SwiftUI
import TipKit

/// The current sale, always on screen beside the scan zone. Yellow items stay off the total until picked.
struct TicketPanel: View {
    @Bindable var app: AppModel

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(TrainingSamples.optInKey) private var trainingOn = false
    @State private var picking: Region?
    @State private var adding = false
    /// The Add item option picked, opened once the options sheet is gone.
    @State private var chosen: AddItemSheet.Choice?
    @State private var listRoute: AddItemSheet.Choice?
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
                // Up here, not under the lines: with a dozen items it sat a long scroll down.
                if app.scan != nil {
                    Button("Add item", systemImage: "plus") { adding = true }
                        .font(.seed(.subheadline, .bold))
                        .labelStyle(AdaptiveLabel(iconOnly: sizeClass == .compact))
                        .accessibilityLabel(Text("Add item"))
                        .buttonStyle(.glass)
                } else {
                    TimelineView(.everyMinute) { context in
                        Text(context.date, style: .time).font(.seed(.subheadline)).foregroundStyle(Brand.muted)
                    }
                }
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
        // Add item: the options first; a list or barcode pick opens once they've gone (one sheet at a time).
        .sheet(isPresented: $adding, onDismiss: {
            listRoute = chosen
            chosen = nil
        }) {
            AddItemSheet { choice in
                switch choice {
                case .oneShot:
                    app.scanningMore = true   // the pager turns to the scanner
                    if app.demo { app.demoIndex += 1 }   // the next table, not the one just billed
                case .barcode, .list:
                    chosen = choice
                }
                adding = false
            }
            .presentationDetents([.height(300)])
        }
        .sheet(item: $listRoute) { route in
            PickListView(region: nil, catalog: app.catalog, onPick: { sku in
                app.scan?.manual.append(sku)
                listRoute = nil
            }, startsWithBarcode: route == .barcode)
        }
        .fullScreenCover(isPresented: $paying) {
            PayView(total: total, catalog: app.catalog, onPaid: { method, received in
                do {
                    let sale = try SalesLog.record(lines, total: total, method: method, received: received,
                                                   ringUp: chargedAt.flatMap { charged in app.scan.map { charged.timeIntervalSince($0.lockedAt) } },
                                                   autoUnits: app.scan?.autoUnits, in: context)
                    app.applyToStock(sale)
                    if let scan = app.scan { TrainingSamples.keep(scan) }   // opt-in only; checked inside
                    return sale
                } catch {
                    // The customer has paid: PayView says so, and the next customer isn't blocked.
                    Log.error("sale not logged: \(error)")
                    return nil
                }
            }, onDone: {
                paying = false
                app.clearSale()
            })
        }
    }

    /// The full welcome where there's room, just the line where there isn't: the footer with Charge always shows.
    private var emptyState: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 14) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(Brand.accent)
                Text("Ready for the next customer").font(.seed(.title3)).foregroundStyle(Brand.ink)
                Text("Hold the camera over the items, then tap Scan.")
                    .font(.seed(.callout))
                    .foregroundStyle(Brand.body)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            Text("Ready for the next customer").font(.seed(.callout)).foregroundStyle(Brand.body).padding(8)
            Color.clear.frame(height: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var items: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
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
        }
        .padding(.bottom, 12)
    }

    private func lineRow(_ line: BillLine) -> some View {
        // iPhone: when the full name doesn't fit beside the stepper, the stepper and amount drop below it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                lineName(line)
                Spacer(minLength: 4)
                lineAmount(line)
            }
            VStack(alignment: .trailing, spacing: 0) {
                lineName(line).frame(maxWidth: .infinity, alignment: .leading)
                lineAmount(line)
            }
        }
        .font(.seed(.title3))
        .buttonStyle(.borderless)
        .padding(10)
        .background(Brand.card.opacity(0.7), in: .rect(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func lineName(_ line: BillLine) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: line.product)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.product.name).font(.seed(.headline)).foregroundStyle(Brand.ink).lineLimit(1)
                Text("\(line.product.price.baht) each").font(.seed(.subheadline)).foregroundStyle(Brand.muted).lineLimit(1)
            }
        }
    }

    private func lineAmount(_ line: BillLine) -> some View {
        HStack(spacing: 12) {
            // 44 pt targets inside the labels (a frame outside a Button doesn't grow what it hits); one tight group,
            // so the name keeps its width in the 400 pt ticket. At ~21 pt, 12 pt apart, a + on stage hit the −.
            HStack(spacing: 0) {
                Button { app.scan?.removeOne(line.product.id) } label: {
                    Image(systemName: "minus.circle.fill").frame(width: 44, height: 44).contentShape(.rect)
                }
                .foregroundStyle(Brand.muted)
                .accessibilityLabel(Text("Remove one \(line.product.name)"))
                Text("\(line.quantity)").font(.seed(.headline)).foregroundStyle(Brand.ink).frame(minWidth: 22)
                // A pack hidden under another one: the camera can't see it, the cashier can.
                Button { app.scan?.manual.append(line.product.id) } label: {
                    Image(systemName: "plus.circle.fill").frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel(Text("Add one \(line.product.name)"))
            }
            Text(line.amount.baht).font(.seed(.headline)).foregroundStyle(Brand.ink).frame(minWidth: 56, alignment: .trailing)
        }
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
            // App Store 2.5.14: a visible sign whenever this sale's photo will be kept for training.
            if trainingOn, app.scan != nil {
                Label("This photo helps improve OneShot", systemImage: "sparkles")
                    .font(.seed(.caption))
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !unsure.isEmpty {
                Label("^[\(unsure.count) item](inflect: true) to check before paying", systemImage: "exclamationmark.triangle.fill")
                    .font(.seed(.callout))
                    .foregroundStyle(Brand.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { app.clearSale() }
                    .labelStyle(AdaptiveLabel(iconOnly: sizeClass == .compact))   // iPhone: Charge gets the width
                    .accessibilityLabel(Text("Start over"))
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
                Log.error("pick embed failed: \(error)")
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

/// Add item, from the cart: OneShot's camera first and obvious, then a barcode, then the list.
struct AddItemSheet: View {
    enum Choice: Identifiable { case oneShot, barcode, list; var id: Self { self } }
    let onChoose: (Choice) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Add items").font(.seed(.headline)).foregroundStyle(Brand.ink).padding(.top, 6)
            Button { onChoose(.oneShot) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.18), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scan with OneShot").font(.seed(.headline))
                        Text("Point the camera at the items").font(.seed(.caption)).opacity(0.85)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(Brand.buttonFill, in: .rect(cornerRadius: 20, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                Button { onChoose(.barcode) } label: {
                    IconRow("Scan a barcode", subtitle: "For a pack with a barcode", icon: "barcode.viewfinder", tint: Brand.sky)
                        .padding(14)
                }
                Divider().padding(.leading, 56)
                Button { onChoose(.list) } label: {
                    IconRow("Choose from the list", icon: "list.bullet", tint: Brand.muted).padding(14)
                }
            }
            .buttonStyle(.plain)
            .background(Brand.card, in: .rect(cornerRadius: 20, style: .continuous))
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.canvas)
    }
}
