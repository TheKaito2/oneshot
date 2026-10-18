import CoreGraphics
import Foundation
import Testing
@testable import OneShot

struct BillTests {
    let catalog = Catalog(products: [
        Product(id: "lays", nameEN: "Lay's", nameTH: "เลย์", price: Decimal(string: "20")!, barcode: nil),
        Product(id: "pocky", nameEN: "Pocky", nameTH: "ป๊อกกี้", price: Decimal(string: "19.9")!, barcode: nil),
    ])

    private let image: CGImage = {
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    private func item(_ detector: [(String, Float)], gallery: [(String, Float)] = [],
                      rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)) -> Detection {
        Detection(rect: rect, crop: image,
                  detector: detector.map { Guess(label: $0.0, confidence: $0.1) },
                  gallery: gallery.map { Guess(label: $0.0, confidence: $0.1) })
    }

    @Test func billCountsSureItemsAndLeavesYellowOff() {
        var scan = LockedScan(image: image, detections: [
            item([("lays", 0.9)]),
            item([("pocky", 0.8)]),
            item([("lays", 0.7)]),
            item([("pocky", 0.3), ("lays", 0.2)]),   // weak: yellow
            item([("person", 0.9), ("lays", 0.6)]),   // best label isn't a product: yellow, never "lays"
        ], catalog: catalog, resolver: Resolver())

        #expect(scan.regions.count == 5)
        #expect(scan.unsure.count == 2)
        #expect(scan.unsure.last?.verdict == .unsure(candidates: []))
        #expect(scan.lines(catalog: catalog).map { "\($0.product.id)×\($0.quantity)" } == ["lays×2", "pocky×1"])
        #expect(scan.total(catalog: catalog) == Decimal(string: "59.9")!)

        scan.removeOne("lays")
        #expect(scan.total(catalog: catalog) == Decimal(string: "39.9")!)
        #expect(scan.unsure.count == 2)
    }

    @Test func galleryNamesWhatTheDetectorCant() {
        let scan = LockedScan(image: image, detections: [
            item([], gallery: [("pocky", 0.9)]),                    // mask instance the detector missed
            item([("person", 0.9)], gallery: [("pocky", 0.85)]),    // detector has no product label
            item([], gallery: [("pocky", 0.4), ("lays", 0.3)]),     // gallery unsure: yellow with its guesses
            item([("lays", 0.9)], gallery: [("ghost", 0.99)]),      // gallery SKU not in catalog: ignored
        ], catalog: catalog, resolver: Resolver())

        #expect(scan.regions.map(\.verdict) == [
            .sure(sku: "pocky", by: .gallery),
            .sure(sku: "pocky", by: .gallery),
            .unsure(candidates: ["pocky", "lays"]),
            .sure(sku: "lays", by: .detector),
        ])
    }

    private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let middle = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)

    // The cases below are the measured locks of 18 Oct, with "pocky" standing in for the quick-added item.

    @Test func containerAroundTheItemBillsItOnce() {
        // Lock D: "table" 0.851 around the bag's own box at 0.928.
        let scan = LockedScan(image: image, detections: [
            item([("dining table", 0.99)], gallery: [("pocky", 0.851)], rect: whole),
            item([("cake", 0.91)], gallery: [("pocky", 0.928)], rect: middle),
        ], catalog: catalog, resolver: Resolver())
        #expect(scan.regions.map(\.id) == [1])
        #expect(scan.total(catalog: catalog) == Decimal(string: "19.9")!)
    }

    @Test func closeUpKeepsTheBetterOfTwoNestedViews() {
        // Lock A: the table box is nearly the whole bag (0.790, green); the bag's own box is 0.774 (yellow).
        // Picking that yellow used to bill the bag twice.
        let scan = LockedScan(image: image, detections: [
            item([("cake", 0.94)], gallery: [("pocky", 0.774)], rect: middle),
            item([("dining table", 1.0)], gallery: [("pocky", 0.790)], rect: whole),
        ], catalog: catalog, resolver: Resolver())
        #expect(scan.regions.map(\.verdict) == [.sure(sku: "pocky", by: .gallery)])
    }

    @Test func subPartInsideTheItemIsDropped() {
        // Lock F: "keyboard" 0.711 inside the MacBook's "laptop" box at 0.896.
        let scan = LockedScan(image: image, detections: [
            item([("laptop", 1.0)], gallery: [("pocky", 0.896)], rect: whole),
            item([("keyboard", 1.0)], gallery: [("pocky", 0.711)], rect: middle),
        ], catalog: catalog, resolver: Resolver())
        #expect(scan.regions.map(\.id) == [0])
        #expect(scan.unsure.isEmpty)
    }

    @Test func containerNamingSomethingElseStays() {
        // A container whose own match differs from the item inside is not a duplicate of it.
        let scan = LockedScan(image: image, detections: [
            item([("dining table", 0.9)], gallery: [("pocky", 0.8)], rect: whole),
            item([("lays", 0.9)], rect: middle),
        ], catalog: catalog, resolver: Resolver())
        #expect(scan.lines(catalog: catalog).count == 2)
    }

    @Test func productBoxHoldingAnotherProductKeepsBoth() {
        let scan = LockedScan(image: image, detections: [
            item([("lays", 0.9)], rect: CGRect(x: 0, y: 0, width: 0.8, height: 0.8)),
            item([("pocky", 0.9)], rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)),
        ], catalog: catalog, resolver: Resolver())
        #expect(scan.lines(catalog: catalog).count == 2)
    }

    @Test func handAddedUnitsCountAndGoFirst() {
        // Two Lay's stacked: the camera sees one, the cashier taps +; Add item covers one it missed entirely.
        var scan = LockedScan(image: image, detections: [item([("lays", 0.9)])], catalog: catalog, resolver: Resolver())
        scan.manual += ["lays", "pocky"]
        #expect(scan.lines(catalog: catalog).map { "\($0.product.id)×\($0.quantity)" } == ["lays×2", "pocky×1"])
        #expect(scan.total(catalog: catalog) == Decimal(string: "59.9")!)
        scan.removeOne("lays")   // removes the hand-added one, the camera's region stays
        #expect(scan.manual == ["pocky"])
        #expect(scan.regions.count == 1)
    }

    @Test func scanningMoreKeepsTheFirstBatch() {
        var first = LockedScan(image: image, detections: [item([("lays", 0.9)]), item([("pocky", 0.3), ("lays", 0.2)])],
                               catalog: catalog, resolver: Resolver())
        first.manual = ["pocky"]
        let second = LockedScan(image: image, detections: [item([("lays", 0.9)]), item([("pocky", 0.9)])],
                                catalog: catalog, resolver: Resolver())
        let merged = first.adding(second)

        #expect(merged.lines(catalog: catalog).map { "\($0.product.id)×\($0.quantity)" } == ["lays×2", "pocky×2"])
        #expect(merged.unsure.count == 1)                                    // the first frame's yellow item still waits
        #expect(Set(merged.regions.map(\.id)).count == merged.regions.count) // picks and removals find the right one
        #expect(merged.regions.filter(\.earlier).count == 2)                 // only the new frame's boxes are drawn
        #expect(merged.lockedAt == first.lockedAt)                           // ring-up time runs from the first tap
    }

    @Test func typedAmountsParseStrictly() {
        #expect(Decimal(baht: "25") == 25)
        #expect(Decimal(baht: " 1,250 ") == 1250)          // was ฿1: Decimal(string:) stopped at the comma
        #expect(Decimal(baht: "฿59.90") == Decimal(string: "59.9")!)
        #expect(Decimal(baht: "12.345") == nil)            // satang has 2 places
        #expect(Decimal(baht: "12abc") == nil)
        #expect(Decimal(baht: "") == nil)
        #expect(Decimal(baht: "-5") == nil)
    }

    @Test func cropRectFlipsVisionOrigin() {
        // Vision's bottom-left quarter is the pixel rect's bottom-left quarter (origin top-left).
        let rect = LockedScan.pixelRect(for: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), width: 1080, height: 1920)
        #expect(rect == CGRect(x: 0, y: 960, width: 540, height: 960))
    }

    @Test func pricesReadLikeAThaiShop() {
        #expect(Decimal(25).baht == "฿25")
        #expect(Decimal(string: "59.9")!.baht == "฿59.90")
        #expect(Decimal(5165).baht == "฿5,165")
        #expect(Decimal(-55).baht == "−฿55")
    }

    @Test func pricesDecodeExactly() throws {
        let json = #"[{"id":"a","nameEN":"A","nameTH":"เอ","price":19.9,"barcode":null},{"id":"b","nameEN":"B","nameTH":"บี","price":12.5,"barcode":null}]"#
        let products = try JSONDecoder().decode([Product].self, from: Data(json.utf8))
        #expect(products.map(\.price) == [Decimal(string: "19.9")!, Decimal(string: "12.5")!])
    }
}
