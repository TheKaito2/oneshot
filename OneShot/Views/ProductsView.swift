import SwiftUI

/// Every product the shop sells: its photo, price and what OneShot has learned about it.
struct ProductsView: View {
    let app: AppModel
    @State private var selected: Product?
    @State private var query = ""

    /// The chips under the search field: every product, one shelf group, or what's running low.
    private enum Filter: Hashable {
        case all, lowStock
        case category(ProductCategory)
    }
    @State private var filter = Filter.all

    private var products: [Product] {
        app.catalog.products.filter { product in
            let matches = query.isEmpty || product.nameEN.localizedCaseInsensitiveContains(query) || product.nameTH.contains(query)
            switch filter {
            case .all: return matches
            case .lowStock: return matches && app.stock[product.id]?.isLow == true
            case .category(let category): return matches && (product.category ?? .other) == category
            }
        }
    }

    /// Only the groups the shop actually sells, and Low stock only while something is low.
    private var filters: [Filter] {
        let present = Set(app.catalog.products.map { $0.category ?? .other })
        let low = app.catalog.products.contains { app.stock[$0.id]?.isLow == true }
        return [.all] + (low ? [.lowStock] : []) + ProductCategory.allCases.filter(present.contains).map(Filter.category)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { option in
                    let on = option == filter
                    Button { withAnimation(.snappy) { filter = option } } label: {
                        Group {
                            switch option {
                            case .all: Text("All")
                            case .lowStock: Label("Low stock", systemImage: "exclamationmark.triangle.fill")
                            case .category(let category): Text(category.title)
                            }
                        }
                        .font(.seed(.subheadline, .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(on ? .white : Brand.ink)
                        .background(on ? AnyShapeStyle(Brand.buttonFill) : AnyShapeStyle(Brand.card), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                chips.padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {   // 2 across on iPhone
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
                    .accessibilityHidden(true)
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
    /// Photos from the training shoot that the gallery also knows it by (bundled, so they can't be deleted here).
    @State private var seedPhotos = 0
    @State private var deleting = false
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
                // Apple Settings' header card: the product, big, with its price as the one accent.
                Section {
                    VStack(spacing: 8) {
                        ProductPhoto(product: product)
                            .frame(width: 120, height: 120)
                            .clipShape(.rect(cornerRadius: 26, style: .continuous))
                            .padding(.bottom, 4)
                        Text(product.nameEN).font(.seed(.title2, .bold)).foregroundStyle(Brand.ink).multilineTextAlignment(.center)
                        Text(product.nameTH).font(.seed(.subheadline)).foregroundStyle(Brand.muted).multilineTextAlignment(.center)
                        Text((Decimal(baht: price) ?? product.price).baht)
                            .font(.seed(size: 30, .extraBold, relativeTo: .title))
                            .foregroundStyle(Brand.accent)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                Section {
                    field("Price", icon: "tag.fill", tint: Brand.accent, text: $price, prompt: "0")
                    field("Cost", icon: "cart.fill", tint: Brand.sand, text: $cost, prompt: String(localized: "Optional"))
                    if let error { Text(error).foregroundStyle(Brand.negative).font(.seed(.caption)) }
                } header: {
                    InfoHeader("Selling", info: "Cost is what you pay for one. It's only used for profit in Reports.")
                } footer: {
                    if let marginText { Text(marginText) }
                }
                .frostedRows()
                Section {
                    Toggle(isOn: $tracked) {
                        IconRow("Track stock", icon: "shippingbox.fill", tint: Brand.sage)
                    }
                    if tracked {
                        Stepper(value: $count, in: 0...9999) {
                            LabeledContent("On the shelf") { Text("\(count)").monospacedDigit().foregroundStyle(Brand.ink) }
                        }
                        Stepper(value: $reorderAt, in: 0...999) {
                            LabeledContent("Reorder at") { Text("\(reorderAt)").monospacedDigit().foregroundStyle(Brand.ink) }
                        }
                        HStack {
                            Text("Stock in")
                            Spacer()
                            ForEach([6, 12, 24], id: \.self) { n in
                                Button("+\(n)") { count += n }.buttonStyle(.glass)
                            }
                        }
                    }
                } header: {
                    InfoHeader("Stock", info: "Sales take from the shelf, refunds put back. At or below the reorder point it shows on Home.")
                }
                .frostedRows()
                Section {
                    NavigationLink { photosPage } label: {
                        IconRow("Photos", icon: "photo.stack.fill", tint: Brand.sky,
                                value: "\(photos.count + seedPhotos)")
                    }
                    NavigationLink { barcodesPage } label: {
                        IconRow("Barcodes", icon: "barcode", tint: Brand.mauve,
                                value: "\(catalog.barcodes(for: product.id).count)")
                    }
                } header: {
                    InfoHeader("Recognition", info: "What OneShot knows it by: the photos it learned from, and barcodes scanned for it.")
                }
                .frostedRows()
                if Catalog.isQuickAdd(product.id) {
                    Section {
                        Button("Delete this product", systemImage: "trash", role: .destructive) { deleting = true }
                    } footer: {
                        Text("For a test or duplicate teach. Past sales keep their lines.")
                    }
                    .frostedRows()
                }
            }
            .gridList()
            .confirmationDialog("Delete \(product.name)?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete product", role: .destructive) { deleteProduct() }
            } message: {
                Text("OneShot stops recognising it, and its photos are removed.")
            }
            .navigationTitle(product.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .onAppear {
            photos = CropStore.photos(for: product.id)
            seedPhotos = Gallery.bundledSeeds()[product.id]?.count ?? 0
            price = "\(product.price)"
            cost = product.cost.map { "\($0)" } ?? ""
            tracked = stock != nil
            count = stock?.count ?? 0
            reorderAt = stock?.reorderAt ?? 5
        }
    }

    /// A Settings-style row with the number typed on the right, like the iOS Settings fields.
    private func field(_ title: LocalizedStringKey, icon: String, tint: Color, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, tint: tint)
            Text(title).foregroundStyle(Brand.ink)
            Spacer(minLength: 8)
            HStack(spacing: 3) {   // ฿ hugs the number
                Text(verbatim: "฿").foregroundStyle(Brand.muted)
                TextField(prompt, text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
            }
        }
    }

    private var photosPage: some View {
        Form {
            Section {
                if photos.isEmpty {
                    Text(seedPhotos > 0
                         ? "Known from \(seedPhotos) training photos. Each time you pick it from a yellow item, that photo is added here."
                         : "No photos yet. Teach it, or pick it once from a yellow item.")
                        .foregroundStyle(Brand.muted)
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
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var barcodesPage: some View {
        Form {
            Section {
                let codes = catalog.barcodes(for: product.id)
                if codes.isEmpty {
                    Text("None yet. Scan one from Add item › Scan a barcode, then pick this product, and it's remembered.")
                        .foregroundStyle(Brand.muted)
                } else {
                    ForEach(codes, id: \.self) { Text($0).monospacedDigit() }
                }
            }
            .frostedRows()
        }
        .gridList()
        .navigationTitle("Barcodes")
        .navigationBarTitleDisplayMode(.inline)
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

    private func deleteProduct() {
        do {
            try Catalog.removeQuickAdd(product.id)
            gallery.remove(product.id)
            onStock(nil)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
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
