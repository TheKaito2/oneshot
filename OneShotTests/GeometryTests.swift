import CoreGraphics
import ImageIO
import Testing
@testable import OneShot

struct GeometryTests {
    @Test func rotationAngleMapsToOrientation() {
        #expect(CGImagePropertyOrientation(rotationAngle: 0) == .up)
        #expect(CGImagePropertyOrientation(rotationAngle: 90) == .right)
        #expect(CGImagePropertyOrientation(rotationAngle: 180) == .down)
        #expect(CGImagePropertyOrientation(rotationAngle: 270) == .left)
        #expect(CGImagePropertyOrientation(rotationAngle: 360) == .up)
        #expect(CGImagePropertyOrientation.right.uprightSize(1920, 1080) == CGSize(width: 1080, height: 1920))
        #expect(CGImagePropertyOrientation.up.uprightSize(1920, 1080) == CGSize(width: 1920, height: 1080))
    }

    @Test func aspectFillMapsVisionRectToView() {
        // A 1080×1920 frame filling an 820×1180 view: scale 0.7593, shown 820×1457.8, overflowing 138.9 pt top and bottom.
        let image = CGSize(width: 1080, height: 1920)
        let view = CGSize(width: 820, height: 1180)

        let whole = BoxOverlay.viewRect(for: CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: image, in: view)
        #expect(close(whole, CGRect(x: 0, y: -138.89, width: 820, height: 1457.78)))

        // Vision's origin is bottom-left, so its lower-left quarter lands at the bottom of the view.
        let lowerLeft = BoxOverlay.viewRect(for: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), imageSize: image, in: view)
        #expect(close(lowerLeft, CGRect(x: 0, y: 590, width: 410, height: 728.89)))
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 0.05 }
    }
}
