import SwiftUI

/// Every product the shop sells: its photo, price and what OneShot has learned about it.
struct ProductsView: View {
    let app: AppModel
    @State private var selected: Product?
    @State private var query = ""

    private var products: [Product] {
        guard !query.isEmpty else { return app.catalog.products }
        return app.catalog.products.filter {
            $0.nameEN.localizedCaseInsensitiveContains(query) || $0.nameTH.contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                    Button { app.startTeaching() } label: { teachCard }
                        .buttonStyle(.plain)
                    ForEach(products) { product in
                        Button { selected = product } label: { ProductCard(product: product, catalog: app.catalog, stock: app.stock[product.id]) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .background(GridBackground())
            .navigationTitle("Products")
            .searchable(text: $query, prompt: "Search items")
            .sheet(item: $selected) { product in
                ProductDetail(product: product, catalog: app.catalog, gallery: app.gallery, stock: app.stock[product.id],
                              onSaved: { app.reloadCatalog() },
                              onStock: { level in
                                  if let level {
                                      app.stock.set(product.id, count: level.count, reorderAt: level.reorderAt)
                                  } else {
                                      app.stock.untrack(product.id)
                                  }
                                  app.saveStock()
                              })
            }
        }
    }

    /// The way to add a product: an ember card with the chameleon engraving looking on.
    private var teachCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.viewfinder").font(.system(size: 40, weight: .semibold))
            Text("Teach a product").font(.seed(.headline))
            Text("8 photos, no retraining").font(.seed(.caption)).opacity(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 236)
        .background {
            ZStack(alignment: .bottomTrailing) {
                Brand.buttonFill
                Image("Chameleon").resizable().scaledToFit().frame(height: 150).opacity(0.3).offset(x: 30, y: 24)
            }
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
        }
    }
}

private struct ProductCard: View {
    let product: Product
    let catalog: Catalog
    let stock: StockLevel?

    var body: some View {
        let photos = CropStore.photos(for: product.id).count
        VStack(alignment: .leading, spacing: 0) {
            // The slot sets the size; a scaled-to-fill photo laid over it can't widen the card.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .overlay { ProductPhoto(product: product) }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous))
            // Card title, then the Thai name a step down in colour, then the price as the one accent.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(product.nameEN).font(.seed(.title3)).foregroundStyle(Brand.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if let stock {
                        Text("\(stock.count) left")
                            .font(.seed(.caption, .bold))
                            .foregroundStyle(stock.isLow ? Brand.warning : Brand.muted)
                    }
                }
                Text(product.nameTH).font(.seed(.subheadline)).foregroundStyle(Brand.body).lineLimit(1)
                HStack(alignment: .firstTextBaseline) {
                    Text(product.price.baht).font(.seed(size: 22, .extraBold, relativeTo: .title2)).foregroundStyle(Brand.accent)
                    Spacer()
                    if !catalog.barcodes(for: product.id).isEmpty {
                        Image(systemName: "barcode").foregroundStyle(Brand.muted)
                    }
                    if photos > 0 {
                        Label("\(photos)", systemImage: "photo.stack").font(.seed(.caption, .bold)).foregroundStyle(Brand.muted)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .card(padding: 0)   // only the photo is clipped: clipping the card would mute its secondary text
    }
}

/// One product: change its price, see the photos OneShot learned it from.
private struct ProductDetail: View {
    let product: Product
    let catalog: Catalog
    let gallery: Gallery
    let stock: StockLevel?
    let onSaved: () -> Void
    /// nil = stop tracking this product's stock.
    let onStock: ((count: Int, reorderAt: Int)?) -> Void

    @State private var price = ""
    @State private var cost = ""
    @State private var tracked = false
    @State private var count = 0
    @State private var reorderAt = 5
    @State private var error: String?
    @State private var photos: [URL] = []
    @Environment(\.dismiss) private var dismiss

    /// Live as the owner types: what one unit earns.
    private var marginText: String? {
        guard let sell = Decimal(baht: price), sell > 0, let paid = Decimal(baht: cost) else { return nil }
        let margin = ((sell - paid) / sell).double.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Profit \((sell - paid).baht) a unit · margin \(margin)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        ProductPhoto(product: product)
                            .frame(width: 96, height: 96)
                            .clipShape(.rect(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.nameEN).font(.seed(.title2, .bold))
                            Text(product.nameTH).foregroundStyle(Brand.muted)
                        }
                    }
                }
                .frostedRows()
                Section {
                    TextField("Price ฿", text: $price).keyboardType(.decimalPad)
                    TextField("Cost ฿ (what you pay)", text: $cost).keyboardType(.decimalPad)
                    if let marginText { Text(marginText).font(.seed(.caption)).foregroundStyle(Brand.muted) }
                    if let error { Text(error).foregroundStyle(Brand.negative).font(.seed(.caption)) }
                } header: {
                    Text("Price")
                } footer: {
                    Text("The cost is only used for profit in Reports. Leave it empty if you don't know it.")
                }
                .frostedRows()
                Section {
                    Toggle("Track stock", isOn: $tracked)
                    if tracked {
                        Stepper("On the shelf: \(count)", value: $count, in: 0...9999)
                        Stepper("Reorder at: \(reorderAt)", value: $reorderAt, in: 0...999)
                        HStack {
                            Text("Received")
                            Spacer()
                            ForEach([6, 12, 24], id: \.self) { n in
                                Button("+\(n)") { count += n }.buttonStyle(.glass)
                            }
                        }
                    }
                } header: {
                    Text("Stock")
                } footer: {
                    Text("Sales take from the shelf, refunds put back. At or below the reorder point it shows on Home.")
                }
                .frostedRows()
                if !catalog.barcodes(for: product.id).isEmpty {
                    Section("Barcodes") {
                        ForEach(catalog.barcodes(for: product.id), id: \.self) { Text($0).monospacedDigit() }
                    }
                    .frostedRows()
                }
                Section {
                    if photos.isEmpty {
                        Text("No photos yet. Teach it, or pick it once from a yellow item.").foregroundStyle(Brand.muted)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                            ForEach(photos, id: \.self) { url in
                                AsyncLocalImage(url: url)
                                    .frame(height: 84)
                                    .clipShape(.rect(cornerRadius: 10))
                                    .contentShape(.contextMenuPreview, .rect(cornerRadius: 10))
                                    .contextMenu {
                                        Button("Delete photo", systemImage: "trash", role: .destructive) { delete(url) }
                                    }
                            }
                        }
                    }
                } header: {
                    Text("Learned from ^[\(photos.count) photo](inflect: true)")
                } footer: {
                    if !photos.isEmpty { Text("Touch and hold a photo to delete it, for example a wrong pick or a blurry shot.") }
                }
                .frostedRows()
            }
            .gridList()
            .navigationTitle(product.nameEN)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .onAppear {
            photos = CropStore.photos(for: product.id)
            price = "\(product.price)"
            cost = product.cost.map { "\($0)" } ?? ""
            tracked = stock != nil
            count = stock?.count ?? 0
            reorderAt = stock?.reorderAt ?? 5
        }
    }

    /// Gone from disk at once; the gallery forgets it in the background.
    private func delete(_ url: URL) {
        do {
            try CropStore.delete(url)
        } catch {
            self.error = error.localizedDescription
            return
        }
        withAnimation { photos.removeAll { $0 == url } }
        onSaved()   // reloads the catalog, so the grid's photo count follows
        let sku = product.id, gallery = gallery
        Task.detached(priority: .utility) { gallery.rebuild(sku) }
    }

    private func save() {
        guard let value = Decimal(baht: price), value > 0 else {
            error = String(localized: "Enter a price above zero, like 25 or 59.50.")
            return
        }
        let costText = cost.trimmingCharacters(in: .whitespaces)
        let unitCost = Decimal(baht: costText)
        guard costText.isEmpty || unitCost != nil else {
            error = String(localized: "Enter a cost like 18 or 18.50, or leave it empty.")
            return
        }
        do {
            try Catalog.savePrice(value, for: product.id)
            try Catalog.saveCost(costText.isEmpty ? nil : unitCost, for: product.id)
            onStock(tracked ? (count, reorderAt) : nil)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A learned photo from disk, loaded off the main thread.
private struct AsyncLocalImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemGroupedBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .clipped()
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path()) }.value
        }
    }
}
