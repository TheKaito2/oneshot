import SwiftUI

/// Teach a new product in about 10 seconds: 8 shots of the item on its own, then a name and a price.
/// No retraining; the gallery names it from the next lock on.
struct QuickAddPanel: View {
    let camera: CameraController
    let gallery: Gallery
    /// Called after the crops and vectors are stored; the caller adds the product to the catalog.
    let onSave: (Product) throws -> Void
    let onCancel: () -> Void

    private struct Shot: Identifiable {
        let id = UUID()
        let frame: CGImage
        /// Normalised Vision rect of the item in `frame`.
        let item: CGRect
        let crop: CGImage
        let vector: [Float]
    }

    static let shotsNeeded = 8

    @State private var shots: [Shot] = []
    @State private var busy = false
    @State private var note: String?
    @State private var nameEN = ""
    @State private var nameTH = ""
    @State private var price = ""
    /// Name or price has the keyboard: the photos fold away so the fields stay above it.
    @FocusState private var typing: Bool

    private var parsedPrice: Decimal? {
        Decimal(baht: price).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teach a new product").font(.seed(.title3, .bold))
                    Text("8 photos and a price. No retraining.").font(.seed(.callout)).foregroundStyle(Brand.muted)
                }
                Spacer()
                Button("Cancel", action: onCancel)
            }
            if !typing {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Brand.sky.opacity(0.25), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(shots.count) / CGFloat(Self.shotsNeeded))
                            .stroke(Brand.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(shots.count)/\(Self.shotsNeeded)").font(.seed(.headline))
                    }
                    .frame(width: 64, height: 64)
                    .animation(.spring, value: shots.count)
                    Text("Put the item on its own with a gap around it. Turn it a little between shots.")
                        .font(.seed(.callout))
                        .foregroundStyle(Brand.muted)
                }
                if let note {
                    Text(note).font(.seed(.callout)).padding(10).background(.yellow, in: .rect(cornerRadius: 10)).foregroundStyle(.black)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(shots) { shot in
                        Image(decorative: shot.crop, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 72)
                            .frame(maxWidth: .infinity)
                            .clipShape(.rect(cornerRadius: 12))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring, value: shots.count)
            }
            Spacer(minLength: 0)
            if shots.count < Self.shotsNeeded {
                Button {
                    Task { await shoot() }
                } label: {
                    Label(busy ? "Hold still…" : "Take photo", systemImage: "camera.fill")
                        .font(.seed(.title3, .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .primaryButton()
                .disabled(busy)
                .accessibilityLabel("Take shot")
            } else {
                VStack(spacing: 10) {
                    TextField("Name (English)", text: $nameEN).focused($typing)
                    TextField("ชื่อ (ภาษาไทย, optional)", text: $nameTH).focused($typing)
                    TextField("Price ฿", text: $price).keyboardType(.decimalPad).focused($typing)
                }
                .textFieldStyle(.roundedBorder)
                Button("Save item") { save() }
                    .primaryButton()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(nameEN.trimmingCharacters(in: .whitespaces).isEmpty || parsedPrice == nil)
            }
        }
        .padding(20)
        .animation(.easeOut(duration: 0.25), value: typing)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 0)
    }

    private func shoot() async {
        busy = true
        defer { busy = false }
        do {
            let image = try await camera.freeze()
            let start = ContinuousClock.now
            let shot = try await Task.detached(priority: .userInitiated) { () throws -> Shot? in
                guard let item = try Splitter.mainItem(in: image),
                      let crop = image.cropping(to: LockedScan.pixelRect(for: item, width: image.width, height: image.height))
                else { return nil }
                return Shot(frame: image, item: item, crop: crop, vector: try Gallery.embed(crop))
            }.value
            print(String(format: "quickadd shot ms=%.0f found=%d", (ContinuousClock.now - start) / .milliseconds(1), shot == nil ? 0 : 1))
            if let shot {
                shots.append(shot)
                note = nil
            } else {
                note = String(localized: "Couldn't see the item. Leave a gap around it and try again.")
            }
        } catch {
            note = error.localizedDescription
        }
    }

    private func save() {
        guard let price = parsedPrice else { return }
        let name = nameEN.trimmingCharacters(in: .whitespaces)
        let thai = nameTH.trimmingCharacters(in: .whitespaces)
        let product = Product(id: "qa-\(Int(Date().timeIntervalSince1970))", nameEN: name,
                              nameTH: thai.isEmpty ? name : thai, price: price, barcode: nil)
        do {
            try onSave(product)
            for (index, shot) in shots.enumerated() {
                CropStore.save(shot.crop, sku: product.id)
                // Full frames with the item rect, so background crops can be measured as negatives (calibration).
                let r = shot.item
                CropStore.write(shot.frame, to: String(format: "Debug/%@/frame-%d_%.3f-%.3f-%.3f-%.3f.jpg",
                                                       product.id, index, r.minX, r.minY, r.width, r.height))
            }
            gallery.add(shots.map(\.vector), to: product.id)
        } catch {
            note = String(localized: "Couldn't save the item: \(error.localizedDescription)")
        }
    }
}
