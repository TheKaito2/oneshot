import AVFoundation
import PhotosUI
import SwiftUI
import TipKit

/// The selling screen: a framed scan zone with its controls, and the sale beside it (stacked in portrait).
/// Ring up freezes one frame in the zone and fills the ticket in place.
struct CheckoutView: View {
    @Bindable var app: AppModel

    @State private var locking = false
    @State private var lockError: String?
    @State private var photo: PhotosPickerItem?
    @State private var flash: Color?
    @State private var shutter = false
    @State private var addingByHand = false
    /// Demo camera: the photo in the zone and the boxes the detector draws on it, as the live preview would.
    @State private var demoFrame: CGImage?
    @State private var demoBoxes: [Box] = []
    @AppStorage(SettingsKey.debugOverlay) private var debugOverlay = false
    /// One tip at a time under the zone: how to ring up first, then how to teach a product.
    @State private var tips = TipGroup(.ordered) {
        LockTip()
        QuickAddTip()
    }

    private var camera: CameraController { app.camera }

    var body: some View {
        GeometryReader { geometry in
            // Side by side only when the zone keeps room for its controls beside the ticket. Decided by the width
            // the tab actually gets, not the orientation: with the sidebar docked in landscape it gets ~860 pt, and
            // side by side there crushed the controls until Ring up wrapped one letter a line (seen 18 Oct).
            // The ticket keeps a full 400 pt beside it: at ~320 its item names wrapped one letter a line (seen 18 Oct).
            let wide = geometry.size.width >= 960
            // Stacked (iPhone, iPad portrait): no empty ticket under the camera. The camera gets the screen, upright
            // and tall, until Ring up; then the cart slides in from the right (Krist, 22 Oct).
            let cameraOnly = !wide && !billOpen && !app.teaching
            let layout = wide ? AnyLayout(HStackLayout(spacing: 20)) : AnyLayout(VStackLayout(spacing: 20))
            layout {
                VStack(spacing: 14) {
                    // Stacked: the zone takes its 36 % first and the ticket's list scrolls in the rest. Without the
                    // priority, landscape with the sidebar docked squeezed the zone to ~200 pt (19 Oct).
                    // iPhone with a bill open: the frozen photo shrinks so the ticket shows more than one line.
                    let zoneShare = billOpen && geometry.size.height < 800 ? 0.22 : 0.36
                    scanZone.frame(maxHeight: wide || cameraOnly ? .infinity : geometry.size.height * zoneShare)
                        .frame(minHeight: wide || cameraOnly ? nil : geometry.size.height * min(zoneShare, 0.3))
                    // Tips only where they fit: on a short stacked screen they pushed Charge off the bottom.
                    // iPhone with a bill open or teaching: the greyed controls took the panel's room (seen 19–20 Oct);
                    // the bill's own Add items / Start over buttons and the panel's Cancel cover what's left to do.
                    if !((billOpen || app.teaching) && geometry.size.height < 800) {
                        controls(tipsFit: wide || cameraOnly || geometry.size.height > 1000)
                    }
                }
                if !cameraOnly {
                    sidePanel
                        .frame(width: wide ? 400 : nil)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(20)
            .animation(.spring(duration: 0.45, bounce: 0.15), value: cameraOnly)
        }
        // The workspace doesn't scroll: at accessibility text sizes the ticket pushed Charge off the screen (18 Oct).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(GridBackground())
        .animation(.easeOut(duration: 0.3), value: flash)
        .animation(.spring, value: app.teaching)
        .alert("Couldn't ring up", isPresented: Binding(get: { lockError != nil }, set: { if !$0 { lockError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lockError ?? "")
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await billPhoto(item) }
        }
        .onChange(of: app.scan?.id) { _, id in
            if id != nil { Task { await signalLock() } }
        }
        .task(id: app.demo ? app.demoIndex : -1) { await loadDemoFrame() }
    }

    /// The sale, or the Teach-a-product panel while teaching.
    @ViewBuilder
    private var sidePanel: some View {
        if app.teaching {
            QuickAddPanel(camera: camera, gallery: app.gallery,
                          onSave: { product in
                              try Catalog.saveQuickAdd(product)
                              app.catalog = app.catalog.adding(product)
                              app.teaching = false
                          },
                          onCancel: { app.teaching = false })
        } else {
            TicketPanel(app: app)
        }
    }

    // MARK: - Scan zone

    private var scanZone: some View {
        ZStack {
            Color.black
            if let scan = app.scan, !app.scanningMore, !app.teaching {
                Image(decorative: scan.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        BoxOverlay(marks: marks(for: scan), imageSize: CGSize(width: scan.image.width, height: scan.image.height),
                                   fill: false, reveal: true)
                            .id(scan.id)
                    }
            } else if app.demo, !app.teaching {
                demoFeed
            } else {
                switch camera.state {
                case .idle:
                    ProgressView().tint(.white)
                case .running:
                    CameraPreview(session: camera.session, onAngle: camera.setPreviewAngle)
                    if !app.teaching {
                        BoxOverlay(marks: liveMarks(camera.boxes), imageSize: camera.frameSize)
                    }
                    ScanSweep()
                case .denied:
                    message(String(localized: "Camera access is off. Turn it on in Settings › OneShot."))
                case .failed(let text):
                    message(text)
                }
            }
            ScanCorners(color: app.scan == nil || app.scanningMore ? Brand.accent : .white.opacity(0.5))
            // The shutter: one white blink when the frame freezes.
            Color.white.opacity(shutter ? 0.85 : 0).allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { camera.setVisibleAspect($0.width / $0.height) }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 1)
        }
        // Dash Cart-style light: green = all logged, amber = check something.
        .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(flash ?? .clear, lineWidth: 10) }
        // Bottom centre, between the corner marks: it never covers the label of a box at the top of the frame.
        .overlay(alignment: .bottom) {
            statusChip.padding(.bottom, 14)
        }
        .overlay(alignment: .topLeading) {
            if app.demo, !app.teaching, app.scan == nil || app.scanningMore {
                Button("Next photo", systemImage: "arrow.forward") { app.demoIndex += 1 }
                    .buttonStyle(.glass)
                    .padding(14)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if app.teaching {
                    EmptyView()   // the bill waits under Teach; its controls come back with it
                } else if app.scanningMore {
                    Button("Back to the bill", systemImage: "xmark") { app.scanningMore = false }
                } else if app.scan != nil {
                    ViewThatFits(in: .horizontal) {
                        billButtons
                        billButtons.labelStyle(.iconOnly)   // iPhone
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(14)
        }
        .sheet(isPresented: $addingByHand) {
            PickListView(region: nil, catalog: app.catalog, onPick: { sku in
                app.scan?.manual.append(sku)
                addingByHand = false
            })
        }
    }

    private var billButtons: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Scan more items", systemImage: "viewfinder") {
                    app.scanningMore = true
                    if app.demo { app.demoIndex += 1 }   // the next table, not the one just billed
                }
                Button("Add an item by hand", systemImage: "hand.tap") { addingByHand = true }
            } label: {
                Label("Add items", systemImage: "plus")
            }
            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { app.clearSale() }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var statusChip: some View {
        Group {
            if let error = camera.detectorError {
                Text(error)
            } else if app.teaching {
                Label("Teach mode", systemImage: "plus.viewfinder")
            } else if let scan = app.scan, !app.scanningMore, let elapsed = scan.elapsed {
                // The last frame's count and time; after Scan more the bill also holds earlier frames.
                Label("^[\(scan.regions.count { !$0.earlier }) item](inflect: true) in \(String(format: "%.2f", elapsed / .seconds(1))) s",
                      systemImage: "bolt.fill")
            } else if app.demo {
                Label("DEMO", systemImage: "photo")
            } else if debugOverlay {
                Text(String(format: "%.0f fps · detect %.0f ms · %d boxes", camera.fps, camera.detectMs, camera.boxes.count))
                    .monospacedDigit()
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("LIVE")
                }
            }
        }
        .font(.seed(.caption, .bold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    /// A bundled table photo in place of the camera, with the detector's boxes drawn like the live preview's.
    @ViewBuilder
    private var demoFeed: some View {
        if let demoFrame {
            Image(decorative: demoFrame, scale: 1)
                .resizable()
                .scaledToFit()
                .overlay {
                    BoxOverlay(marks: liveMarks(demoBoxes), imageSize: CGSize(width: demoFrame.width, height: demoFrame.height),
                               fill: false)
                }
                .id(app.demoIndex)
                .transition(.opacity)
            ScanSweep()
        } else {
            ProgressView().tint(.white)
        }
    }

    private func loadDemoFrame() async {
        guard app.demo else { return }
        let frame = DemoFeed.frame(app.demoIndex)
        withAnimation { demoFrame = frame; demoBoxes = [] }
        guard let frame else { return }
        // The model may still be loading right after launch; the boxes are decoration, so a miss just leaves none.
        for _ in 0..<20 {
            do {
                let boxes = try await camera.detect(frame)
                guard !Task.isCancelled else { return }   // Next photo was tapped meanwhile
                demoBoxes = boxes
                return
            } catch {
                guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            }
        }
    }

    /// What the detector sees before Ring up: the product's name (not its SKU id) and the detector's confidence.
    private func liveMarks(_ boxes: [Box]) -> [Mark] {
        boxes.enumerated().map { index, box in
            // Names only: with a dozen packs, "99%" on every label crowded them into each other. The HUD shows scores.
            let name = app.catalog[box.label]?.name ?? box.label
            return Mark(id: index, rect: box.rect, label: debugOverlay ? "\(name) \(Int(box.confidence * 100))%" : name,
                        color: .white)
        }
    }

    private func marks(for scan: LockedScan) -> [Mark] {
        let unsureIDs = scan.unsure.map(\.id)
        return scan.regions.filter { !$0.earlier }.map { region in
            if let sku = region.verdict.sku {
                Mark(id: region.id, rect: region.rect, label: app.catalog[sku]?.name ?? sku, color: .green)
            } else {
                Mark(id: region.id, rect: region.rect, label: "? \((unsureIDs.firstIndex(of: region.id) ?? 0) + 1)", color: .yellow)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
    }

    // MARK: - Controls

    private func controls(tipsFit: Bool) -> some View {
        VStack(spacing: 10) {
            // Inline, not a popover: on iPad a popover eats the first tap, and that tap should ring up.
            if app.scan == nil, !app.teaching, tipsFit {
                if let tip = tips.currentTip as? LockTip {
                    TipView(tip)
                } else if let tip = tips.currentTip as? QuickAddTip {
                    TipView(tip)
                }
            }
            // One glass cluster: the shared container renders the buttons as one layer and lets them blend.
            // One row when it fits; otherwise Ring up gets the full width and the rest go underneath.
            GlassEffectContainer(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        secondaryControls.frame(maxWidth: .infinity, alignment: .leading)
                        ringUpButton
                        teachButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    VStack(spacing: 10) {
                        ringUpButton
                        HStack(spacing: 10) {
                            secondaryControls
                            Spacer(minLength: 0)
                            teachButton
                        }
                    }
                    // iPhone: Ring up across the width, the rest as icons (the labelled row ran off the screen).
                    VStack(spacing: 10) {
                        ringUpButton.frame(maxWidth: .infinity)
                        HStack(spacing: 10) {
                            secondaryControls
                            Spacer(minLength: 0)
                            teachButton
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(app.teaching)
            }
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Photo", systemImage: "photo")
            }
            .disabled(locking || billOpen)   // it used to replace the bill on the counter without a word
            // Presenting without the snacks, or from the simulator: table photos stand in for the camera.
            Toggle(isOn: $app.demo) {
                Label("Demo", systemImage: "photo.on.rectangle.angled")
            }
            .toggleStyle(.button)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var teachButton: some View {
        Button {
            QuickAddTip().invalidate(reason: .actionPerformed)
            app.startTeaching()
        } label: {
            Label("Teach", systemImage: "plus.viewfinder")
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var ringUpButton: some View {
        Button {
            Task { await lock() }
        } label: {
            Label(locking ? "Ringing up…" : "Ring up", systemImage: "bolt.fill")
                .font(.seed(.title2, .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
        }
        .primaryButton()
        .disabled(locking || !canRingUp || billOpen || app.teaching)
        .opacity(billOpen || app.teaching ? 0.4 : 1)
        .accessibilityLabel("Ring up the items in view")
    }

    /// A frozen bill is on the counter (not reopened with Scan more).
    private var billOpen: Bool { app.scan != nil && !app.scanningMore }

    /// Something to ring up from: the demo photos, or a camera that is actually running.
    private var canRingUp: Bool {
        guard camera.detectorError == nil else { return false }
        if app.demo { return true }
        if case .running = camera.state { return true }
        return false
    }

    // MARK: - Ring up

    /// Where a ring-up's items go, fixed at the tap: a new bill, or the bill that Scan more reopened.
    /// Anything that changes the sale while the frame is in recognition (Back, Start over, Teach) wins over it.
    private struct Target {
        let adding: Bool
        let saleID: UUID?
        let tapped = Date.now
    }

    private func lock() async {
        LockTip().invalidate(reason: .actionPerformed)
        locking = true
        defer { locking = false }
        let target = Target(adding: app.scanningMore, saleID: app.scan?.id)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            if app.demo, let frame = demoFrame {
                await bill(image: frame, boxes: try await camera.detect(frame), target: target, start: start, clock: clock)
                return
            }
            let (image, boxes) = try await camera.lock()
            await bill(image: image, boxes: boxes, target: target, start: start, clock: clock)
        } catch {
            lockError = error.localizedDescription
        }
    }

    /// Same pipeline as the lock, from a library photo (demo backup, still-photo testing).
    private func billPhoto(_ item: PhotosPickerItem) async {
        locking = true
        defer { locking = false }
        let target = Target(adding: app.scanningMore, saleID: app.scan?.id)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = Self.upright(data) else {
                lockError = String(localized: "Couldn't open that photo.")
                return
            }
            await bill(image: image, boxes: try await camera.detect(image), target: target, start: start, clock: clock)
        } catch {
            lockError = error.localizedDescription
        }
    }

    /// The photo drawn upright and no bigger than a camera frame, so both paths see the same scale.
    private static func upright(_ data: Data, maxSide: CGFloat = 1920) -> CGImage? {
        guard let photo = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(photo.size.width, photo.size.height))
        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in photo.draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }

    private func bill(image: CGImage, boxes: [Box], target: Target, start: ContinuousClock.Instant,
                      clock: ContinuousClock) async {
        LockTip().invalidate(reason: .actionPerformed)
        let gallery = app.gallery
        let detections = await Task.detached(priority: .userInitiated) {
            gallery.detections(in: image, boxes: boxes)
        }.value
        // The sale moved on while this frame was being recognised: drop the frame, keep what the cashier did.
        guard !app.teaching, app.scan?.id == target.saleID, app.scanningMore == target.adding else { return }
        var locked = LockedScan(image: image, detections: detections, catalog: app.catalog, resolver: Resolver())
        locked.elapsed = clock.now - start
        locked.lockedAt = target.tapped   // ring-up time runs from the tap, not from when recognition finished
        // An empty table: say so instead of freezing a bill with nothing on it.
        guard !locked.regions.isEmpty else {
            lockError = String(localized: "No items found. Move closer, or add them by hand.")
            return
        }
        let ms = (clock.now - start) / .milliseconds(1)
        if debugOverlay { dumpForCalibration(image: image, detections: detections) }
        // Both voters' top pick per region, to measure where the thresholds belong.
        let votes = detections.map { d in
            let l1 = d.detector.first.map { "\($0.label):\(Int($0.confidence * 100))" } ?? "-"
            // Top-2 too: the margin between look-alikes (Lay's flavours) needs measuring.
            let l2 = d.gallery.prefix(2).map { "\($0.label):\(String(format: "%.3f", $0.confidence))" }
                .joined(separator: ",")
            return "\(l1)|\(l2)"
        }
        Log.info(String(format: "lock ms=%.0f boxes=%d regions=%d unsure=%d ", ms, boxes.count, locked.regions.count,
                        locked.unsure.count) + votes.joined(separator: " "))
        if target.adding, let earlier = app.scan {
            app.scan = earlier.adding(locked)
        } else {
            app.scan = locked
        }
        app.scanningMore = false
    }

    /// The sale's arrival, heard and seen: a bright chime if everything is named, a low double beep if not.
    private func signalLock() async {
        guard let scan = app.scan else { return }
        let allSure = scan.unsure.isEmpty && !scan.regions.isEmpty
        shutter = true
        withAnimation(.easeOut(duration: 0.35)) { shutter = false }
        Chime.play(allSure ? .ok : .check)
        flash = allSure ? .green : .orange
        try? await Task.sleep(for: .milliseconds(450))   // only cancellation can throw; the flash just stays off
        flash = nil
    }

    /// Settings › Debug: keeps every lock for threshold calibration.
    /// Documents/Debug/lock-<ms>/frame.jpg plus one crop per region named <i>_<detector>_<gallery>.jpg.
    private func dumpForCalibration(image: CGImage, detections: [Detection]) {
        let folder = "Debug/lock-\(Int(Date().timeIntervalSince1970 * 1000))"
        Task.detached(priority: .background) {
            CropStore.write(image, to: "\(folder)/frame.jpg")
            for (index, d) in detections.enumerated() {
                let l1 = d.detector.first.map { "\($0.label)-\(Int($0.confidence * 100))" } ?? "none"
                let l2 = d.gallery.first.map { "\($0.label)-\(Int($0.confidence * 1000))" } ?? "none"
                CropStore.write(d.crop, to: "\(folder)/\(index)_\(l1)_\(l2).jpg")
            }
        }
    }
}

/// Short bundled tones (tools/make_tones.py). The iPad has no haptics, so sound is the feedback channel.
enum Chime: String {
    case ok, check

    @MainActor private static var players: [Chime: AVAudioPlayer] = [:]

    @MainActor static func play(_ chime: Chime) {
        if players[chime] == nil {
            guard let url = Bundle.main.url(forResource: chime.rawValue, withExtension: "wav") else {
                Log.error("missing \(chime.rawValue).wav")
                return
            }
            do {
                players[chime] = try AVAudioPlayer(contentsOf: url)
            } catch {
                Log.error("chime: \(error)")
                return
            }
        }
        players[chime]?.currentTime = 0
        players[chime]?.play()
    }
}
