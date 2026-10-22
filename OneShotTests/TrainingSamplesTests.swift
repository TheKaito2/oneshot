import CoreGraphics
import Foundation
import Testing
@testable import OneShot

/// The labels a training photo carries: what the cashier confirmed by charging, in YOLO's top-left frame.
struct TrainingSamplesTests {
    private let crop: CGImage = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    @Test func boxesFlipVisionOriginToTopLeft() {
        // Vision: x 0.1, y 0.6 (from the bottom), 0.2 × 0.3 → centre (0.2, 0.75) bottom-left → (0.2, 0.25) top-left.
        let regions = [Region(id: 0, rect: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), crop: crop,
                              verdict: .sure(sku: "lays", by: .detector))]
        let box = TrainingSamples.boxes(in: regions).first
        #expect(box?.sku == "lays")
        #expect(box?.source == "detector")
        #expect(abs((box?.cx ?? 0) - 0.2) < 1e-9)
        #expect(abs((box?.cy ?? 0) - 0.25) < 1e-9)
        #expect(abs((box?.w ?? 0) - 0.2) < 1e-9)
        #expect(abs((box?.h ?? 0) - 0.3) < 1e-9)
    }

    @Test func boxesClampToTheFrame() {
        let regions = [Region(id: 0, rect: CGRect(x: -0.1, y: 0.9, width: 0.3, height: 0.3), crop: crop,
                              verdict: .sure(sku: "lays", by: .gallery))]
        let box = TrainingSamples.boxes(in: regions).first
        #expect(abs((box?.w ?? 0) - 0.2) < 1e-9)    // x −0.1…0.2 clamped to 0…0.2
        #expect(abs((box?.h ?? 0) - 0.1) < 1e-9)    // y 0.9…1.2 clamped to 0.9…1
        #expect(abs((box?.cy ?? 0) - 0.05) < 1e-9)
    }

    @Test func leavesOutYellowAndEarlierFrames() {
        var earlier = Region(id: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), crop: crop,
                             verdict: .sure(sku: "pocky", by: .cashier))
        earlier.earlier = true   // Scan more: its box belongs to another photo
        let regions = [
            Region(id: 0, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), crop: crop, verdict: .unsure(candidates: ["lays"])),
            earlier,
            Region(id: 2, rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), crop: crop, verdict: .sure(sku: "lays", by: .cashier)),
        ]
        #expect(TrainingSamples.boxes(in: regions).map(\.sku) == ["lays"])
        #expect(TrainingSamples.boxes(in: regions).first?.source == "cashier")
    }
}
