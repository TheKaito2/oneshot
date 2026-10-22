import SwiftUI

/// For a yellow region: best guesses as one-tap chips, then search over the whole catalog.
/// Without a region it is "Add item", for a pack the camera missed.
struct PickListView: View {
    let region: Region?
    let catalog: Catalog
    let onPick: (String) -> Void
    var onNotAnItem: (() -> Void)?
    /// Add item › Scan a barcode: the scanner opens first; a code the shop hasn't seen yet falls back to the list.
    var startsWithBarcode = false

    @State private var query = ""
    @State private var scanningBarcode = false
    /// A scanned barcode the catalog doesn't know yet; the next pick remembers it.
    @State private var pendingBarcode: String?
    @Environment(\.dismiss) private var dismiss

    private var candidates: [Product] {
        guard case .unsure(let ids)? = region?.verdict else { return [] }
        return ids.compactMap { catalog[$0] }
    }

    private var results: [Product] {
        guard !query.isEmpty else { return catalog.products }
        return catalog.products.filter {
            $0.nameEN.localizedCaseInsensitiveContains(query) || $0.nameTH.contains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let region {
                        Image(decorative: region.crop, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                    }
                    if let pendingBarcode {
                        Label("New barcode \(pendingBarcode). Pick the item below and it's remembered.",
                              systemImage: "barcode")
                            .foregroundStyle(Brand.warning)
                    }
                    if query.isEmpty, !candidates.isEmpty {
                        HStack {
                            ForEach(candidates) { product in
                                Button { choose(product.id) } label: {
                                    VStack {
                                        ProductPhoto(product: product)
                                            .frame(width: 64, height: 64)
                                            .clipShape(.rect(cornerRadius: 12))
                                        Text(product.name).font(.seed(.headline)).lineLimit(1)
                                        Text(product.price.baht).font(.seed(.caption)).monospacedDigit()
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .primaryButton()
                                .controlSize(.large)
                            }
                        }
                    }
                    if let onNotAnItem {
                        Button("Not an item", systemImage: "xmark.bin", role: .destructive, action: onNotAnItem)
                    }
                }
                .frostedRows()
                Section(query.isEmpty ? "All items" : "Results") {
                    ForEach(results) { product in
                        Button { choose(product.id) } label: {
                            HStack(spacing: 12) {
                                ProductPhoto(product: product)
                                    .frame(width: 40, height: 40)
                                    .clipShape(.rect(cornerRadius: 8))
                                Text(product.nameEN)
                                Text(product.nameTH).foregroundStyle(Brand.muted)
                                Spacer()
                                Text(product.price.baht).monospacedDigit()
                            }
                        }
                    }
                }
                .frostedRows()
            }
            .searchable(text: $query, prompt: "Search items")
            .navigationTitle(region == nil ? Text("Add an item") : Text("Which item is this?"))
            .navigationBarTitleDisplayMode(.inline)
            .gridList()
            // Cancel top-left like every sheet; the destructive 'Not an item' used to sit there.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Barcode", systemImage: "barcode.viewfinder") { scanningBarcode = true }
                }
            }
            .task { if startsWithBarcode { scanningBarcode = true } }
            .sheet(isPresented: $scanningBarcode) {
                BarcodeSheet { code in
                    if let product = catalog.product(barcode: code) {
                        onPick(product.id)
                    } else {
                        pendingBarcode = code
                    }
                }
            }
        }
    }

    private func choose(_ sku: String) {
        if let pendingBarcode {
            do {
                try Catalog.assignBarcode(pendingBarcode, to: sku)
            } catch {
                // The pick still goes through; only the shortcut for next time is lost.
                Log.error("barcode assign failed: \(error)")
            }
        }
        onPick(sku)
    }
}
