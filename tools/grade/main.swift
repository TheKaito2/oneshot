// Grades a detector on the exam (data/raw/mixed-test, 42 real tables) as the till rings it up: the app's whole lock
// path, on the Mac, with no Ultralytics. Built with the app's own Resolver, Detector (types) and Splitter:
//
//   swiftc -O tools/grade/main.swift OneShot/Recognition/{Resolver,Detector,Splitter}.swift OneShot/Log.swift -o build/grade
//   build/grade <model .mlpackage|.mlmodel|.mlmodelc> [--item] [--photos data/raw/mixed-test]
//               [--truth data/exam-truth.tsv]
//
// Per photo, like CheckoutView.lock → Gallery.detections → LockedScan:
//   detector boxes down to the lock floor (0.25) → Gallery.mergeOverlaps → mask instances no box covers (Splitter)
//   → each crop's FeaturePrint against the bundled seed photos → Resolver.verdict.
// --item: a class-agnostic model; its boxes carry no product vote, so the gallery names everything.
// Scores, against the units on each table (see the old grade.py's rules):
//   right = billed units that are on the table · wrong = billed beyond that (a wrong price) · missed = not billed
//   yellow = regions the cashier must pick · exact = a bill with nothing wrong and nothing missed
// Plus the detector alone (the old grade.py number, for calibration) and the box count against the units.
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
    defer { arguments.removeSubrange(index...index + 1) }
    return arguments[index + 1]
}
let mergeIoU = CGFloat(Double(option("--merge", "0.6")) ?? 0.6)   // Gallery.mergeOverlaps' threshold in the app
let nmsIoU = Double(option("--nms", "-1")) ?? -1   // the model's own iouThreshold input; -1 leaves its default
let itemMode = arguments.contains("--item")
arguments.removeAll { $0 == "--item" }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let photosDir = root.appending(path: option("--photos", "data/raw/mixed-test"))
let truthFile = root.appending(path: option("--truth", "data/exam-truth.tsv"))
guard let modelArg = arguments.first else {
    print("usage: grade <model> [--item] [--photos dir] [--truth tsv]")
    exit(2)
}

// MARK: - Gallery (the pure parts of OneShot/Recognition/Gallery.swift, copied: that file needs the app's other types)

enum Gallery {
    static func embed(_ image: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let print = request.results?.first else { return [] }
        let raw: [Float] = print.data.withUnsafeBytes { bytes in
            switch print.elementType {
            case .double: bytes.bindMemory(to: Double.self).map(Float.init)
            default: Array(bytes.bindMemory(to: Float.self))
            }
        }
        let length = zip(raw, raw).reduce(0) { $0 + $1.0 * $1.1 }.squareRoot()
        return length > 0 ? raw.map { $0 / length } : raw
    }

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

    static func covers(_ box: CGRect, _ instance: CGRect) -> Bool {
        let boxArea = box.width * box.height, instanceArea = instance.width * instance.height
        return iou(box, instance) >= 0.3 || (box.contains(CGPoint(x: instance.midX, y: instance.midY)) && instanceArea >= boxArea / 2)
    }

    static func nearest(_ vector: [Float], in views: [String: [[Float]]], k: Int = 3) -> [Guess] {
        let scored = views.map { sku, skuViews in
            Guess(label: sku, confidence: skuViews.map { zip(vector, $0).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? -1)
        }
        return Array(scored.sorted { $0.confidence > $1.confidence }.prefix(k))
    }
}

// MARK: - Inputs

/// Upright and no bigger than a camera frame, like CheckoutView.upright.
func uprightImage(_ url: URL, maxSide: Int = 1920) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxSide]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func pixelRect(_ rect: CGRect, _ image: CGImage) -> CGRect {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    return CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h).integral
}

let photos = (try FileManager.default.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var truth: [String: [String: Int]] = [:]
for line in try String(contentsOf: truthFile, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3 else { continue }
    for photo in photos {
        let stem = photo.deletingPathExtension().lastPathComponent
        if parts[0] <= stem && stem <= parts[1] {
            truth[photo.lastPathComponent] = parts[2].split(separator: ",").reduce(into: [:]) { $0[String($1), default: 0] += 1 }
        }
    }
}
guard truth.count == photos.count else { print("truth covers \(truth.count) of \(photos.count) photos"); exit(1) }

// Gallery views: the bundled seed photos (Resources/Seed/seed-<sku>-<n>.jpg), as a fresh install has them.
var views: [String: [[Float]]] = [:]
let seedDir = root.appending(path: "OneShot/Resources/Seed")
for url in try FileManager.default.contentsOfDirectory(at: seedDir, includingPropertiesForKeys: nil) {
    let name = url.deletingPathExtension().lastPathComponent
    guard url.pathExtension == "jpg", name.hasPrefix("seed-"), let dash = name.lastIndex(of: "-"),
          let image = uprightImage(url) else { continue }
    views[String(name[name.index(name.startIndex, offsetBy: 5)..<dash]), default: []].append(try Gallery.embed(image))
}

// MARK: - Detector

final class Thresholds: NSObject, MLFeatureProvider {
    var featureNames: Set<String> { nmsIoU < 0 ? ["confidenceThreshold"] : ["confidenceThreshold", "iouThreshold"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "confidenceThreshold": MLFeatureValue(double: 0.25)   // CameraController.lockFloor
        case "iouThreshold" where nmsIoU >= 0: MLFeatureValue(double: nmsIoU)
        default: nil
        }
    }
}
var modelURL = URL(fileURLWithPath: modelArg, relativeTo: root)
if modelURL.pathExtension != "mlmodelc" { modelURL = try await MLModel.compileModel(at: modelURL) }
let coreML = try MLModel(contentsOf: modelURL)
let tiled = Detector.inputSide(coreML) < 600   // as the app decides
let vnModel = try VNCoreMLModel(for: coreML)
vnModel.featureProvider = Thresholds()
let request = VNCoreMLRequest(model: vnModel)
request.imageCropAndScaleOption = .scaleFit

// MARK: - Run every photo once; thresholds are swept afterwards

struct Region { let rect: CGRect; let detector: [Guess]; let gallery: [Guess]; let fromMask: Bool }
var found: [String: (boxes: [Box], regions: [Region])] = [:]
var detectMs: [Double] = []
let skus = Set(views.keys)
for (index, photo) in photos.enumerated() {
    guard let image = uprightImage(photo) else { print("unreadable \(photo.lastPathComponent)"); exit(1) }
    let start = CFAbsoluteTimeGetCurrent()
    var raw: [Box] = []
    for tile in tiled ? Detector.tiles : [CGRect(x: 0, y: 0, width: 1, height: 1)] {
        guard let crop = image.cropping(to: Detector.pixelRect(tile, width: image.width, height: image.height)) else { continue }
        try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
        raw += Detector.fromTile((request.results as? [VNRecognizedObjectObservation] ?? []).map {
            Box(rect: $0.boundingBox, guesses: $0.labels.prefix(3).map { Guess(label: $0.identifier, confidence: $0.confidence) })
        }, tile)
    }
    if index > 0 { detectMs.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }   // first call pays the load
    let boxes = Gallery.mergeOverlaps(raw, iou: mergeIoU)
    let missed = try Splitter.instances(in: image).filter { instance in !boxes.contains { Gallery.covers($0.rect, instance) } }
    var regions: [Region] = []
    for (rect, guesses, fromMask) in boxes.map({ ($0.rect, $0.guesses, false) }) + missed.map({ ($0, [Guess](), true) }) {
        guard let crop = image.cropping(to: pixelRect(rect, image)) else { continue }
        let detector = itemMode ? [] : guesses.filter { skus.contains($0.label) }
        regions.append(Region(rect: rect, detector: detector, gallery: Gallery.nearest(try Gallery.embed(crop), in: views),
                              fromMask: fromMask))
    }
    found[photo.lastPathComponent] = (boxes, regions)
}

// MARK: - Scores

func score(_ bill: (String) -> (billed: [String: Int], yellow: Int)) -> String {
    var right = 0, wrong = 0, missed = 0, yellow = 0, exact = 0
    for (name, table) in truth {
        let (billed, yellows) = bill(name)
        var ok = 0, bad = 0, miss = 0
        for (sku, count) in billed { ok += min(count, table[sku] ?? 0); bad += max(0, count - (table[sku] ?? 0)) }
        for (sku, count) in table { miss += max(0, count - (billed[sku] ?? 0)) }
        right += ok; wrong += bad; missed += miss; yellow += yellows
        if bad == 0 && miss == 0 { exact += 1 }
    }
    let units = truth.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    return "right \(right)/\(units)  wrong \(wrong)  missed \(missed)  yellow \(yellow)  exact bills \(exact)/\(truth.count)"
}

print("model: \(modelArg)\(itemMode ? "  (item mode: gallery names everything)" : "")\(tiled ? "  (tiled: frame + 4 tiles)" : "")")
print(String(format: "detector: %.0f ms mean per photo on this Mac", detectMs.reduce(0, +) / Double(max(detectMs.count, 1))))

if !itemMode {
    print("\n-- detector alone (old grade.py; calibration) --")
    for tau: Float in [0.5, 0.6, 0.65, 0.7, 0.8] {
        print("tau \(tau): " + score { name in
            var billed: [String: Int] = [:], yellow = 0
            for box in found[name]!.boxes {
                let torn = box.guesses.count > 1 && box.guesses[1].confidence >= tau
                if box.confidence >= tau && !torn { billed[box.label, default: 0] += 1 } else { yellow += 1 }
            }
            return (billed, yellow)
        })
    }
}

print("\n-- the app: both vote (Resolver), detectorSure × gallerySure --")
for detectorSure: Float in itemMode ? [1] : [0.5, 0.6, 0.7, 0.8] {
    for gallerySure: Float in [0.7, 0.75, 0.78, 0.8, 0.85, 1.01] {
        let resolver = Resolver(detectorSure: detectorSure, gallerySure: gallerySure)
        let label = itemMode ? "gallery \(gallerySure)" : "detector \(detectorSure) gallery \(gallerySure)"
        print(label.padding(toLength: 28, withPad: " ", startingAt: 0) + score { name in
            var billed: [String: Int] = [:], yellow = 0
            for region in found[name]!.regions {
                switch resolver.verdict(detector: region.detector, gallery: region.gallery) {
                case .sure(let sku, _): billed[sku, default: 0] += 1
                case .unsure: yellow += 1
                }
            }
            return (billed, yellow)
        })
    }
}

// Box count against the units on the table (the exam's box labels are partial, so no IoU recall here).
let units = truth.values.reduce(0) { $0 + $1.values.reduce(0, +) }
let strong = found.values.reduce(0) { $0 + $1.boxes.filter { $0.confidence >= 0.5 }.count }
let maskOnly = found.values.reduce(0) { $0 + $1.regions.filter(\.fromMask).count }
print("\nboxes ≥ 0.5 conf: \(strong) for \(units) units on the tables; mask-only regions added: \(maskOnly)")
