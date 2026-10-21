import CoreGraphics
import Foundation
import UIKit

struct Region: Identifiable {
    let id: Int
    /// Normalised to the locked image, Vision space (origin bottom-left).
    let rect: CGRect
    let crop: CGImage
    var verdict: Verdict
    /// Seen in an earlier frame of this sale (Add items › Scan more), so not drawn over the current one.
    var earlier = false
}

struct BillLine: Identifiable, Equatable {
    let product: Product
    let quantity: Int
    var id: String { product.id }
    var amount: Decimal { product.price * Decimal(quantity) }
}

/// One tap of the lock: one frame, its regions, and the bill they make. One frame per bill means
/// nothing is ever counted twice, so no tracker is needed.
struct LockedScan: Identifiable {
    let id = UUID()
    let image: CGImage
    var regions: [Region]
    /// Units the cashier added by hand (+ on a line, or Add item): stacked or hidden packs the camera can't see.
    var manual: [String] = []
    /// Tap to bill, measured; shown on the bill.
    var elapsed: Duration?
    /// When Ring up was tapped; the sale's ring-up time runs from here to Charge.
    var lockedAt = Date.now

    /// Units on the bill that the AI named (detector, gallery or both); picks and hand-adds don't count.
    var autoUnits: Int {
        regions.filter { region in
            if case .sure(_, let source) = region.verdict { source != .cashier } else { false }
        }.count
    }

    init(image: CGImage, detections: [Detection], catalog: Catalog, resolver: Resolver) {
        self.image = image
        let voted = detections.map { detection in
            // A detector whose best label isn't a product (only the COCO stand-in has such classes) casts no vote;
            // never promote its lower guesses.
            let detectorVotes = detection.detector.first.map { catalog[$0.label] != nil } ?? false
            let detector = detectorVotes ? detection.detector.filter { catalog[$0.label] != nil } : []
            let gallery = detection.gallery.filter { catalog[$0.label] != nil }
            return (detectorVotes: detectorVotes, verdict: resolver.verdict(detector: detector, gallery: gallery))
        }
        let names: [Set<String>] = voted.map {
            switch $0.verdict {
            case .sure(let sku, _): [sku]
            case .unsure(let candidates): Set(candidates)
            }
        }
        func galleryScore(_ index: Int, _ skus: Set<String>) -> Float {
            detections[index].gallery.filter { skus.contains($0.label) }.map(\.confidence).max() ?? 0
        }
        regions = detections.indices.compactMap { index in
            // Nested regions naming the same product are one item seen twice: a box with no product vote around it
            // (a COCO "table" or "bed", measured up to 0.956 for the Lay's inside) or a sub-part box inside it.
            // Keep the better gallery match; on a tie keep the inner one.
            let duplicate = detections.indices.contains { other in
                guard other != index else { return false }
                let indexOuter = !voted[index].detectorVotes && Self.contains(detections[index].rect, detections[other].rect)
                let otherOuter = !voted[other].detectorVotes && Self.contains(detections[other].rect, detections[index].rect)
                let shared = names[index].intersection(names[other])
                guard indexOuter || otherOuter, !shared.isEmpty else { return false }
                let mine = galleryScore(index, shared), theirs = galleryScore(other, shared)
                return mine < theirs || (mine == theirs && indexOuter)
            }
            guard !duplicate else { return nil }
            return Region(id: index, rect: detections[index].rect, crop: detections[index].crop, verdict: voted[index].verdict)
        }
    }

    /// A second look for packs the first frame missed: the new frame's items join this bill and nothing on it is
    /// lost. The sale keeps its first lock time; the new frame becomes the one on screen.
    func adding(_ next: LockedScan) -> LockedScan {
        var merged = next
        let offset = (regions.map(\.id).max() ?? -1) + 1
        merged.regions = regions.map { region in
            var region = region
            region.earlier = true
            return region
        } + next.regions.map { Region(id: $0.id + offset, rect: $0.rect, crop: $0.crop, verdict: $0.verdict) }
        merged.manual = manual + next.manual
        merged.lockedAt = lockedAt
        return merged
    }

    /// `outer` holds most of `inner` and is clearly bigger.
    static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let overlap = outer.intersection(inner)
        let innerArea = inner.width * inner.height
        guard !overlap.isNull, innerArea > 0 else { return false }
        return overlap.width * overlap.height >= 0.8 * innerArea && outer.width * outer.height >= 2 * innerArea
    }

    var unsure: [Region] { regions.filter { $0.verdict.sku == nil } }

    /// Sure regions only, in the order each product first appears.
    func lines(catalog: Catalog) -> [BillLine] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for sku in regions.compactMap(\.verdict.sku) + manual {
            if counts[sku] == nil { order.append(sku) }
            counts[sku, default: 0] += 1
        }
        return order.compactMap { sku in catalog[sku].map { BillLine(product: $0, quantity: counts[sku] ?? 0) } }
    }

    func total(catalog: Catalog) -> Decimal {
        lines(catalog: catalog).reduce(0) { $0 + $1.amount }
    }

    /// Removes one unit of `sku`: a hand-added one first, else a region (e.g. the detector boxed a pack twice).
    mutating func removeOne(_ sku: String) {
        if let index = manual.lastIndex(of: sku) {
            manual.remove(at: index)
        } else if let index = regions.lastIndex(where: { $0.verdict.sku == sku }) {
            regions.remove(at: index)
        }
    }

    /// Vision rect (normalised, origin bottom-left) to pixel rect (origin top-left).
    static func pixelRect(for rect: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h).integral
    }
}

/// Every cashier pick becomes a training photo: Documents/Crops/<sku>/, visible in the Files app.
enum CropStore {
    static func save(_ crop: CGImage, sku: String) {
        // Quick-add saves 8 crops in a burst, so the timestamp alone would collide.
        write(crop, to: "Crops/\(sku)/\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).jpg")
    }

    /// A product's learned photos (quick-add shots and cashier picks), oldest first.
    static func photos(for sku: String) -> [URL] {
        let folder = URL.documentsDirectory.appending(path: "Crops/\(sku)", directoryHint: .isDirectory)
        // No folder yet just means no photos yet.
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The owner removes a learned photo (a wrong pick, a blurry shot); rebuild the gallery for its SKU after.
    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// JPEG under Documents. A failed save must not block the sale; it only costs one photo, so it is logged.
    /// A photo that came down from the account's backup, as it was stored.
    static func write(_ data: Data, to relativePath: String) {
        do {
            let url = URL.documentsDirectory.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("photo save failed: \(error)")
        }
    }

    static func write(_ image: CGImage, to relativePath: String) {
        do {
            let url = URL.documentsDirectory.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else {
                Log.error("photo save failed: JPEG encode (\(relativePath))")
                return
            }
            try data.write(to: url)
        } catch {
            Log.error("photo save failed: \(error)")
        }
    }
}
