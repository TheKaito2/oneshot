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
        // Header and the action button stay put; what's between scrolls, so a short iPhone slot can reach it all.
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teach a new product").font(.seed(.title3, .bold))
                    Text("8 photos and a price. No retraining.").font(.seed(.callout)).foregroundStyle(Brand.muted)
                }
                Spacer()
                Button("Cancel", action: onCancel)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !typing { progress }
                    if shots.count >= Self.shotsNeeded {
                        VStack(spacing: 10) {
                            TextField("Name in English", text: $nameEN).focused($typing)
                            TextField("Name in Thai", text: $nameTH).focused($typing)
                            TextField("Price ฿", text: $price).keyboardType(.decimalPad).focused($typing)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
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
                .disabled(busy || !cameraRunning)
                if !cameraRunning {
                    Text("Teaching needs the device's camera. In the simulator, show it with the products already taught.")
                        .font(.seed(.callout))
                        .foregroundStyle(Brand.muted)
                }
            } else {
                Button { save() } label: {
                    Text("Save item").font(.seed(.title3, .bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .primaryButton()
                // Either name will do: a Thai-only shop couldn't save before.
                .disabled((nameEN + nameTH).trimmingCharacters(in: .whitespaces).isEmpty || parsedPrice == nil)
            }
        }
        .padding(20)
        .animation(.easeOut(duration: 0.25), value: typing)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 0)
    }

    /// The shot count, the tip, a failed shot's note and the photos so far.
    @ViewBuilder
    private var progress: some View {
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
            Log.info(String(format: "quickadd shot ms=%.0f found=%d", (ContinuousClock.now - start) / .milliseconds(1), shot == nil ? 0 : 1))
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

    private var cameraRunning: Bool {
        if case .running = camera.state { true } else { false }
    }

    private func save() {
        guard let price = parsedPrice else { return }
        let english = nameEN.trimmingCharacters(in: .whitespaces)
        let thai = nameTH.trimmingCharacters(in: .whitespaces)
        let product = Product(id: "qa-\(Int(Date().timeIntervalSince1970))", nameEN: english.isEmpty ? thai : english,
                              nameTH: thai.isEmpty ? english : thai, price: price, barcode: nil)
        do {
            try onSave(product)
            // The vectors vote at once; the photo files follow off the main thread (16 JPEG encodes froze Save item).
            gallery.add(shots.map(\.vector), to: product.id)
            let shots = shots, id = product.id, calibration = UserDefaults.standard.bool(forKey: SettingsKey.debugOverlay)
            Task.detached(priority: .utility) {
                for (index, shot) in shots.enumerated() {
                    CropStore.save(shot.crop, sku: id)
                    // Settings › Debug: full frames with the item rect, so background crops can be measured as negatives.
                    guard calibration else { continue }
                    let r = shot.item
                    CropStore.write(shot.frame, to: String(format: "Debug/%@/frame-%d_%.3f-%.3f-%.3f-%.3f.jpg",
                                                           id, index, r.minX, r.minY, r.width, r.height))
                }
            }
        } catch {
            note = String(localized: "Couldn't save the item: \(error.localizedDescription)")
        }
    }
}
