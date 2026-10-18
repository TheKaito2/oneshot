// Labels the Nori-pair photos: just the two Lay's Nori bags, lying apart. Vision's instance mask finds both;
// the bigger one (by mask area, so rotation doesn't matter) is the medium bag. Measured: small = 0.76 x medium.
// Photos without exactly two packs, or two packs too close in size to call, are skipped and listed.
//
// Output: data/labels/nori-pair/<photo>.txt (YOLO: class cx cy w h, normalised, origin top-left)
// Build + run: swiftc -O tools/pairlabel.swift -o build/pairlabel && build/pairlabel
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = root.appending(path: "data/raw/nori-pair")
let out = root.appending(path: "data/labels/nori-pair")
let classes = try String(contentsOf: root.appending(path: "data/labels/classes.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
let medium = classes.firstIndex(of: "lays-nori-medium")!, small = classes.firstIndex(of: "lays-nori-small")!
let minArea = 0.002, maxArea = 0.6   // same noise / table limits as autolabel
let minRatio = 1.15                  // sqrt-area ratio; 1.32 expected, below this the call is a guess

struct Pack { var rect: CGRect; var pixels: Int }

/// One entry per instance: box (normalised, origin top-left) and mask pixel count.
func packs(_ url: URL) throws -> [Pack] {
    let request = VNGenerateForegroundInstanceMaskRequest()
    try VNImageRequestHandler(url: url).perform([request])
    guard let mask = request.results?.first?.instanceMask else { return [] }
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
    let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
    var minX = [Int](repeating: .max, count: 256), minY = minX, maxX = [Int](repeating: -1, count: 256), maxY = maxX
    var count = [Int](repeating: 0, count: 256)
    for y in 0..<h {
        for x in 0..<w {
            let l = Int(base[y * row + x])
            guard l != 0 else { continue }
            minX[l] = min(minX[l], x); maxX[l] = max(maxX[l], x)
            minY[l] = min(minY[l], y); maxY[l] = max(maxY[l], y)
            count[l] += 1
        }
    }
    return (1..<256).compactMap { l in
        guard maxX[l] >= 0 else { return nil }
        let r = CGRect(x: CGFloat(minX[l]) / CGFloat(w), y: CGFloat(minY[l]) / CGFloat(h),
                       width: CGFloat(maxX[l] - minX[l] + 1) / CGFloat(w), height: CGFloat(maxY[l] - minY[l] + 1) / CGFloat(h))
        let area = Double(r.width * r.height)
        return area >= minArea && area <= maxArea ? Pack(rect: r, pixels: count[l]) : nil
    }
}

func yolo(_ cls: Int, _ r: CGRect) -> String {
    String(format: "%d %.6f %.6f %.6f %.6f", cls, r.midX, r.midY, r.width, r.height)
}

let fm = FileManager.default
try fm.createDirectory(at: out, withIntermediateDirectories: true)
var labelled = 0, skipped: [String] = []
for name in try fm.contentsOfDirectory(atPath: src.path()).filter({ $0.hasSuffix(".jpg") }).sorted() {
    let found = try packs(src.appending(path: name)).sorted { $0.pixels > $1.pixels }
    guard found.count == 2 else { skipped.append("\(name): \(found.count) packs"); continue }
    let ratio = (Double(found[0].pixels) / Double(found[1].pixels)).squareRoot()
    guard ratio >= minRatio else { skipped.append("\(name): sizes too close (\(String(format: "%.2f", ratio)))"); continue }
    try [yolo(medium, found[0].rect), yolo(small, found[1].rect)].joined(separator: "\n")
        .write(to: out.appending(path: name.replacingOccurrences(of: ".jpg", with: ".txt")), atomically: true, encoding: .utf8)
    labelled += 1
    print(String(format: "%@  medium/small %.2f", name, ratio))
}
print("labelled \(labelled), skipped \(skipped.count)")
skipped.forEach { print("  skipped \($0)") }
