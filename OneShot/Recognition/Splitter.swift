import CoreGraphics
import CoreVideo
import QuartzCore
import Vision

/// Finds separate items with Vision's foreground instance mask. Touching items merge into one instance
/// (measured), so quick-add needs the item on its own. Fails in the Simulator.
enum Splitter {
    /// Instances smaller than this share of the frame are mask noise.
    static let minArea: CGFloat = 0.002

    /// Normalised Vision rects (origin bottom-left), one per instance, largest first.
    static func instances(in image: CGImage) throws -> [CGRect] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let mask = request.results?.first?.instanceMask else { return [] }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let labels = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: rowBytes * height)
        return boundingBoxes(labels: labels, width: width, height: height, rowBytes: rowBytes)
    }

    /// The item being quick-added: the instance under the frame centre, else the largest.
    static func mainItem(in image: CGImage) throws -> CGRect? {
        let all = try instances(in: image)
        return all.first { $0.contains(CGPoint(x: 0.5, y: 0.5)) } ?? all.first
    }

    /// Per-label bounding boxes of a label image (0 = background, row 0 at the top), as normalised Vision rects,
    /// largest first, noise dropped.
    static func boundingBoxes(labels: UnsafeBufferPointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> [CGRect] {
        var minX = [Int](repeating: .max, count: 256), minY = minX
        var maxX = [Int](repeating: -1, count: 256), maxY = maxX
        for y in 0..<height {
            for x in 0..<width {
                let label = Int(labels[y * rowBytes + x])
                guard label != 0 else { continue }
                minX[label] = min(minX[label], x)
                maxX[label] = max(maxX[label], x)
                minY[label] = min(minY[label], y)
                maxY[label] = max(maxY[label], y)
            }
        }
        let w = CGFloat(width), h = CGFloat(height)
        var rects: [CGRect] = []
        for label in 1..<256 where maxX[label] >= 0 {
            let x = CGFloat(minX[label]) / w
            let top = CGFloat(minY[label]) / h
            let bottom = CGFloat(maxY[label] + 1) / h
            let rect = CGRect(x: x, y: 1 - bottom, width: CGFloat(maxX[label] + 1) / w - x, height: bottom - top)
            if rect.width * rect.height >= minArea { rects.append(rect) }
        }
        return rects.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// The first instance mask call took 11.8 s on the Mac, so pay it at launch.
    static func warmUp() {
        let start = CACurrentMediaTime()
        guard let blank = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() else { return }
        do {
            _ = try instances(in: blank)
            _ = try Gallery.embed(blank)
            print(String(format: "warmup ms=%.0f", (CACurrentMediaTime() - start) * 1000))
        } catch {
            print("warmup failed: \(error)")
        }
    }
}
