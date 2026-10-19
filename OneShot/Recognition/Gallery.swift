import CoreGraphics
import Foundation
import ImageIO
import os
import Vision

/// One region's inputs to the vote.
struct Detection {
    /// Normalised, Vision space (origin bottom-left).
    let rect: CGRect
    let crop: CGImage
    /// Raw detector labels, best first; empty for mask instances the detector missed.
    let detector: [Guess]
    /// Nearest gallery SKUs by cosine similarity, best first.
    let gallery: [Guess]
}

/// The few-shot namer: FeaturePrint vectors of each SKU's photos. A region is named by its nearest views.
/// Quick-adds and cashier picks both add views, persisted in Documents/gallery.json.
final class Gallery: @unchecked Sendable {
    // Sendable: `views` is behind a lock; the rest is immutable.
    private let views: OSAllocatedUnfairLock<[String: [[Float]]]>
    private let url: URL
    /// Writes go one at a time and each writes the newest state, so an older snapshot can never land last.
    private let writes = DispatchQueue(label: "oneshot.gallery.writes")
    /// Products deleted this session: a photo-delete rebuild still running for one must not bring it back.
    private let removed = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    init(url: URL = URL.documentsDirectory.appending(path: "gallery.json")) {
        self.url = url
        views = OSAllocatedUnfairLock(initialState: Self.read(url))
    }

    /// After a restore replaced gallery.json.
    func reload() {
        let stored = Self.read(url)
        views.withLock { $0 = stored }
    }

    private static func read(_ url: URL) -> [String: [[Float]]] {
        guard FileManager.default.fileExists(atPath: url.path()) else { return [:] }
        do {
            return try JSONDecoder().decode([String: [[Float]]].self, from: Data(contentsOf: url))
        } catch {
            Log.error("gallery.json unreadable, starting empty: \(error)")
            return [:]
        }
    }

    var isEmpty: Bool { views.withLock { $0.isEmpty } }

    func add(_ vectors: [[Float]], to sku: String) {
        guard !vectors.isEmpty else { return }
        views.withLock { $0[sku, default: []] += vectors }
        persist()
    }

    /// A deleted product stops voting.
    func remove(_ sku: String) {
        removed.withLock { _ = $0.insert(sku) }
        views.withLock { $0[sku] = nil }
        persist()
    }

    /// A product's views again from what is left of its photos (bundled seeds and learned photos), after the owner
    /// deletes one in Products, so a wrong pick stops voting. ponytail: re-embeds all of the SKU's photos (~20), once per delete.
    /// `embed` is swappable because Vision's FeaturePrint doesn't run in the simulator, where the tests do.
    func rebuild(_ sku: String, embed: (URL) -> [Float]? = Gallery.embed(contentsOf:)) {
        let vectors = (Self.bundledSeeds()[sku, default: []] + CropStore.photos(for: sku)).compactMap(embed)
        views.withLock { views in
            guard !removed.withLock({ $0.contains(sku) }) else { return }   // deleted while this ran: stays deleted
            views[sku] = vectors.isEmpty ? nil : vectors
        }
        persist()
    }

    /// Waits for queued writes; the tests read the file right after a change.
    func flush() { writes.sync {} }

    private func persist() {
        writes.async { [self] in
            let snapshot = views.withLock { $0 }
            do {
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                Log.error("gallery save failed: \(error)")
            }
        }
    }

    /// Bundled views (Resources/Seed/seed-<sku>-<n>.jpg, cut from the training shoot) for products the gallery has
    /// never seen. Embedded here, not on the Mac, so the vectors come from this iPad's Vision revision. Once per product.
    func seedFromBundle() {
        let known = views.withLock { Set($0.keys) }
        let files = Self.bundledSeeds().filter { !known.contains($0.key) }
        for (sku, urls) in files {
            add(urls.compactMap(Self.embed(contentsOf:)), to: sku)
        }
        if !files.isEmpty { Log.info("gallery seeded: \(files.count) products") }
    }

    /// The bundled seed photos by SKU.
    static func bundledSeeds() -> [String: [URL]] {
        var files: [String: [URL]] = [:]
        for url in Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [] {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("seed-"), let dash = name.lastIndex(of: "-") else { continue }
            files[String(name[name.index(name.startIndex, offsetBy: 5)..<dash]), default: []].append(url)
        }
        return files
    }

    /// One photo file's FeaturePrint; nil (logged) if it can't be read or embedded.
    static func embed(contentsOf url: URL) -> [Float]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        do {
            return try embed(image)
        } catch {
            Log.error("embed failed (\(url.lastPathComponent)): \(error)")
            return nil
        }
    }

    func nearest(to vector: [Float]) -> [Guess] {
        Self.nearest(vector, in: views.withLock { $0 })
    }

    /// Both voters' inputs for a locked frame: every detector box, plus mask instances no box covers,
    /// so an item the detector missed still shows up (yellow if the gallery doesn't know it either).
    func detections(in image: CGImage, boxes: [Box]) -> [Detection] {
        let boxes = Self.mergeOverlaps(boxes)
        var candidates = boxes.map { (rect: $0.rect, detector: $0.guesses) }
        do {
            let missed = try Splitter.instances(in: image).filter { instance in
                !boxes.contains { Self.covers($0.rect, instance) }
            }
            candidates += missed.map { (rect: $0, detector: []) }
        } catch {
            Log.error("splitter failed: \(error)")
        }
        let galleryEmpty = isEmpty
        return candidates.compactMap { candidate in
            guard let crop = image.cropping(to: LockedScan.pixelRect(for: candidate.rect, width: image.width, height: image.height))
            else { return nil }
            var gallery: [Guess] = []
            if !galleryEmpty {
                do {
                    gallery = nearest(to: try Self.embed(crop))
                } catch {
                    Log.error("embed failed: \(error)")
                }
            }
            return Detection(rect: candidate.rect, crop: crop, detector: candidate.detector, gallery: gallery)
        }
    }

    // MARK: - Pure parts

    /// Boxes on one object with different labels (NMS runs per class, so both survive) become one box carrying
    /// every label. Measured 18 Oct: one phone boxed as "cell phone" and "remote" was billed twice.
    /// ponytail: IoU 0.6 is unmeasured; eval_det (A4) checks it on touching packs.
    static func mergeOverlaps(_ boxes: [Box], iou threshold: CGFloat = 0.6) -> [Box] {
        var kept: [Box] = []
        for box in boxes.sorted(by: { $0.confidence > $1.confidence }) {
            guard let index = kept.firstIndex(where: { iou($0.rect, box.rect) >= threshold }) else {
                kept.append(box)
                continue
            }
            var best: [String: Float] = [:]
            for guess in kept[index].guesses + box.guesses { best[guess.label] = max(best[guess.label] ?? 0, guess.confidence) }
            let guesses = best.map { Guess(label: $0.key, confidence: $0.value) }.sorted { $0.confidence > $1.confidence }
            kept[index] = Box(rect: kept[index].rect, guesses: Array(guesses.prefix(3)))
        }
        return kept
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let shared = overlap.width * overlap.height
        return shared / (a.width * a.height + b.width * b.height - shared)
    }

    /// A detector box already accounts for a mask instance if it overlaps it well, or if the instance is a blob of
    /// merged items around the box. A much bigger box (table, bed) is a container and accounts for nothing:
    /// measured 18 Oct, a "bed" box hid the Lay's instance on it.
    static func covers(_ box: CGRect, _ instance: CGRect) -> Bool {
        let boxArea = box.width * box.height, instanceArea = instance.width * instance.height
        return iou(box, instance) >= 0.3 || (box.contains(CGPoint(x: instance.midX, y: instance.midY)) && instanceArea >= boxArea / 2)
    }

    /// Top-k SKUs by their best-matching view.
    static func nearest(_ vector: [Float], in views: [String: [[Float]]], k: Int = 3) -> [Guess] {
        let scored = views.map { sku, skuViews in
            Guess(label: sku, confidence: skuViews.map { dot(vector, $0) }.max() ?? -1)
        }
        return Array(scored.sorted { $0.confidence > $1.confidence }.prefix(k))
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let length = dot(vector, vector).squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Vision

    /// L2-normalised FeaturePrint, so a dot product is the cosine similarity.
    static func embed(_ image: CGImage) throws -> [Float] {
        #if targetEnvironment(simulator)
        // FeaturePrint doesn't work in the simulator (no inference context, or identical vectors on the CPU), and its
        // GPU path can abort the app there; the detector alone names the demo tables.
        throw CocoaError(.featureUnsupported)
        #endif
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let print = request.results?.first else { return [] }
        let raw: [Float] = print.data.withUnsafeBytes { bytes in
            switch print.elementType {
            case .double: bytes.bindMemory(to: Double.self).map(Float.init)
            default: Array(bytes.bindMemory(to: Float.self))
            }
        }
        return normalized(raw)
    }
}
