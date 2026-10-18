// Auto-labels the shoot for YOLO training.
//
//  single-product photos (data/raw/sku/<id>/): every foreground instance is that product (gaps between packs,
//    per the shot list, keep them separate). Boxes come from Vision's instance mask.
//  mixed photos (data/raw/mixed-*/): instance boxes, each named by its nearest single-product crop (FeaturePrint),
//    with the score, so the review can find the doubtful ones.
//
// Output: data/labels/<split>/<name>.txt (YOLO: class cx cy w h, normalised, origin top-left),
//         data/labels/review.jsonl (one line per photo, for the contact sheets), data/labels/classes.txt.
//
// Build + run: swiftc -O tools/autolabel.swift -o build/autolabel && build/autolabel
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let raw = root.appending(path: "data/raw")
let out = root.appending(path: "data/labels")
let minArea: CGFloat = 0.002   // smaller is mask noise
let maxArea: CGFloat = 0.6     // bigger is the table, not a pack

func image(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Normalised rects, origin top-left, one per instance, noise and table-sized blobs dropped.
func instances(_ image: CGImage) throws -> [CGRect] {
    let request = VNGenerateForegroundInstanceMaskRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    guard let mask = request.results?.first?.instanceMask else { return [] }
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
    let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
    var minX = [Int](repeating: .max, count: 256), minY = minX, maxX = [Int](repeating: -1, count: 256), maxY = maxX
    for y in 0..<h {
        for x in 0..<w {
            let l = Int(base[y * row + x])
            guard l != 0 else { continue }
            minX[l] = min(minX[l], x); maxX[l] = max(maxX[l], x)
            minY[l] = min(minY[l], y); maxY[l] = max(maxY[l], y)
        }
    }
    var rects: [CGRect] = []
    for l in 1..<256 where maxX[l] >= 0 {
        let r = CGRect(x: CGFloat(minX[l]) / CGFloat(w), y: CGFloat(minY[l]) / CGFloat(h),
                       width: CGFloat(maxX[l] - minX[l] + 1) / CGFloat(w), height: CGFloat(maxY[l] - minY[l] + 1) / CGFloat(h))
        let area = r.width * r.height
        if area >= minArea, area <= maxArea { rects.append(r) }
    }
    return rects
}

func crop(_ image: CGImage, _ r: CGRect) -> CGImage? {
    let W = CGFloat(image.width), H = CGFloat(image.height)
    return image.cropping(to: CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H).integral)
}

func embed(_ image: CGImage) throws -> [Float] {
    let request = VNGenerateImageFeaturePrintRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    guard let print = request.results?.first else { return [] }
    let v: [Float] = print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return n > 0 ? v.map { $0 / n } : v
}

func yolo(_ cls: Int, _ r: CGRect) -> String {
    String(format: "%d %.6f %.6f %.6f %.6f", cls, r.midX, r.midY, r.width, r.height)
}

struct Review: Encodable {
    let image: String
    let boxes: [[Double]]      // x, y, w, h normalised, origin top-left
    let labels: [String]
    let scores: [Double]       // 1 for single-product photos; cosine for mixed
}

let fm = FileManager.default
let skus = try fm.contentsOfDirectory(atPath: raw.appending(path: "sku").path()).filter { !$0.hasPrefix(".") }.sorted()
try fm.createDirectory(at: out, withIntermediateDirectories: true)
try (skus.joined(separator: "\n") + "\n").write(to: out.appending(path: "classes.txt"), atomically: true, encoding: .utf8)
var reviews: [Review] = []
var gallery: [(sku: String, v: [Float])] = []
let started = Date()

// Single-product photos.
for (cls, sku) in skus.enumerated() {
    let dir = raw.appending(path: "sku/\(sku)")
    let labelDir = out.appending(path: "sku/\(sku)")
    try fm.createDirectory(at: labelDir, withIntermediateDirectories: true)
    for name in try fm.contentsOfDirectory(atPath: dir.path()).filter({ $0.hasSuffix(".jpg") }).sorted() {
        guard let img = image(dir.appending(path: name)) else { continue }
        let rects = try instances(img)
        try rects.map { yolo(cls, $0) }.joined(separator: "\n")
            .write(to: labelDir.appending(path: name.replacingOccurrences(of: ".jpg", with: ".txt")), atomically: true, encoding: .utf8)
        for r in rects { if let c = crop(img, r) { gallery.append((sku, try embed(c))) } }
        reviews.append(Review(image: "sku/\(sku)/\(name)", boxes: rects.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) },
                              labels: rects.map { _ in sku }, scores: rects.map { _ in 1 }))
    }
    print("\(sku): done (\(gallery.count) crops so far, \(Int(Date().timeIntervalSince(started))) s)")
}

// Mixed photos: name each instance by its nearest single-product crop.
for split in ["mixed-train", "mixed-test", "unknown", "empty"] {
    let dir = raw.appending(path: split)
    let labelDir = out.appending(path: split)
    try fm.createDirectory(at: labelDir, withIntermediateDirectories: true)
    for name in try fm.contentsOfDirectory(atPath: dir.path()).filter({ $0.hasSuffix(".jpg") }).sorted() {
        guard let img = image(dir.appending(path: name)) else { continue }
        // Empty surfaces are negatives: no boxes, whatever the mask thinks.
        let rects = split == "empty" ? [] : try instances(img)
        var labels: [String] = [], scores: [Double] = [], lines: [String] = []
        for r in rects {
            guard let c = crop(img, r) else { continue }
            let v = try embed(c)
            var best = ("?", -1.0 as Float)
            for g in gallery {
                let s = zip(v, g.v).reduce(0) { $0 + $1.0 * $1.1 }
                if s > best.1 { best = (g.sku, s) }
            }
            labels.append(best.0); scores.append(Double(best.1))
            if let cls = skus.firstIndex(of: best.0) { lines.append(yolo(cls, r)) }
        }
        try lines.joined(separator: "\n")
            .write(to: labelDir.appending(path: name.replacingOccurrences(of: ".jpg", with: ".txt")), atomically: true, encoding: .utf8)
        reviews.append(Review(image: "\(split)/\(name)", boxes: rects.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) },
                              labels: labels, scores: scores))
    }
    print("\(split): done (\(Int(Date().timeIntervalSince(started))) s)")
}

let encoder = JSONEncoder()
try reviews.map { String(data: try encoder.encode($0), encoding: .utf8)! }.joined(separator: "\n")
    .write(to: out.appending(path: "review.jsonl"), atomically: true, encoding: .utf8)
print("labelled \(reviews.count) photos, \(reviews.reduce(0) { $0 + $1.boxes.count }) boxes")
