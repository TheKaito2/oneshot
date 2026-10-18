import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OneShot

struct GalleryTests {
    @Test func nearestRanksSkusByBestView() {
        let views: [String: [[Float]]] = [
            "a": [[1, 0, 0], [0, 1, 0]],
            "b": [Gallery.normalized([1, 1, 0])],
            "c": [[0, 0, 1]],
        ]
        let guesses = Gallery.nearest(Gallery.normalized([1, 0.1, 0]), in: views, k: 2)
        #expect(guesses.map(\.label) == ["a", "b"])
        #expect(abs(guesses[0].confidence - 0.995) < 0.001)
    }

    @Test func normalizedHasUnitLength() {
        let v = Gallery.normalized([3, 4])
        #expect(abs(v[0] - 0.6) < 1e-6 && abs(v[1] - 0.8) < 1e-6)
        #expect(Gallery.normalized([0, 0]) == [0, 0])
    }

    @Test func boxCoversInstanceByOverlapOrCentre() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        #expect(Gallery.covers(box, CGRect(x: 0.15, y: 0.15, width: 0.4, height: 0.4)))   // IoU 0.62
        #expect(Gallery.covers(box, CGRect(x: 0.0, y: 0.0, width: 0.9, height: 0.9)))     // merged blob: IoU 0.2, centre inside
        #expect(!Gallery.covers(box, CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)))    // corner overlap, centre outside
        #expect(!Gallery.covers(box, CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)))    // separate item
        // A container box (table, bed) doesn't account for the small item lying on it.
        #expect(!Gallery.covers(CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)))
    }

    @Test func rebuildForgetsDeletedPhotos() throws {
        let sku = "test-\(UUID().uuidString)"
        let file = URL.temporaryDirectory.appending(path: "\(sku).json")
        defer {
            try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "Crops/\(sku)"))
            try? FileManager.default.removeItem(at: file)
        }
        let gallery = Gallery(url: file)
        // Two real pack photos (bundled seeds) stand in for learned ones.
        for url in try #require(Gallery.bundledSeeds()["kitkat-original"]).prefix(2) {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            CropStore.save(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), sku: sku)
        }
        func views() throws -> Int? { gallery.flush(); return try JSONDecoder().decode([String: [[Float]]].self, from: Data(contentsOf: file))[sku]?.count }

        gallery.rebuild(sku) { _ in [1, 0] }
        #expect(try views() == 2)
        try CropStore.delete(try #require(CropStore.photos(for: sku).first))
        gallery.rebuild(sku) { _ in [1, 0] }
        #expect(try views() == 1)
        try CropStore.delete(try #require(CropStore.photos(for: sku).first))
        gallery.rebuild(sku) { _ in [1, 0] }
        #expect(try views() == nil)   // no photos left: the SKU stops voting
    }

    @Test func boundingBoxesPerLabel() {
        // 4×2 label image, row 0 at the top: label 1 is the top-left 2×1, label 2 the bottom-right 1×1.
        let labels: [UInt8] = [1, 1, 0, 0,
                               0, 0, 0, 2]
        let rects = labels.withUnsafeBufferPointer {
            Splitter.boundingBoxes(labels: $0, width: 4, height: 2, rowBytes: 4)
        }
        #expect(rects == [CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5)])
    }
}

struct MergeTests {
    private func box(_ rect: CGRect, _ labels: [(String, Float)]) -> Box {
        Box(rect: rect, guesses: labels.map { Guess(label: $0.0, confidence: $0.1) })
    }

    @Test func oneObjectTwoLabelsBecomesOneBox() throws {
        // Measured: a phone boxed as "cell phone" 0.86 and "remote" 0.63 at almost the same place.
        let phone = CGRect(x: 0.6, y: 0.3, width: 0.17, height: 0.3)
        let merged = Gallery.mergeOverlaps([
            box(phone, [("cell phone", 0.86), ("remote", 0.01)]),
            box(phone.insetBy(dx: 0.005, dy: 0.005), [("remote", 0.63), ("cell phone", 0.2)]),
            box(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), [("cup", 0.9)]),
        ])
        #expect(merged.count == 2)
        let phoneBox = try #require(merged.first { $0.label == "cell phone" })
        #expect(phoneBox.guesses.map(\.label) == ["cell phone", "remote"])
        #expect(phoneBox.guesses.last?.confidence == 0.63)
    }
}
