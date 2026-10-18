// Cuts every pack out of its photo (Vision instance mask, transparent background).
//
//  build/cutouts             single-product photos -> data/cutouts/<sku>/<photo>-<n>.png, for tools/compose_piles.py
//  build/cutouts <src> <dest> any folder of photos -> <dest>/<photo>-<n>.png (tools/pack_sizes.py measures these)
// Build: swiftc -O tools/cutouts.swift -o build/cutouts
import CoreImage
import Foundation
import Vision

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let minArea = 0.002, maxArea = 0.6   // same noise / table limits as autolabel
let context = CIContext()
let fm = FileManager.default

/// Writes one PNG per instance of every .jpg in `dir`; returns how many.
func cut(_ dir: URL, to dest: URL) throws -> Int {
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    var count = 0
    for name in try fm.contentsOfDirectory(atPath: dir.path()).filter({ $0.hasSuffix(".jpg") }).sorted() {
        let handler = VNImageRequestHandler(url: dir.appending(path: name))
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first,
              let source = CIImage(contentsOf: dir.appending(path: name)) else { continue }
        let imageArea = Double(source.extent.width * source.extent.height)
        for (n, instance) in result.allInstances.enumerated() {
            let buffer = try result.generateMaskedImage(ofInstances: [instance], from: handler, croppedToInstancesExtent: true)
            let cut = CIImage(cvPixelBuffer: buffer)
            let area = Double(cut.extent.width * cut.extent.height) / imageArea
            guard area >= minArea, area <= maxArea else { continue }
            let file = dest.appending(path: "\(name.dropLast(4))-\(n).png")
            try context.writePNGRepresentation(of: cut, to: file, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            count += 1
        }
    }
    return count
}

let args = CommandLine.arguments
if args.count == 3 {
    print("\(try cut(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))) cutouts -> \(args[2])")
} else {
    let raw = root.appending(path: "data/raw/sku"), out = root.appending(path: "data/cutouts")
    var total = 0
    for sku in try fm.contentsOfDirectory(atPath: raw.path()).filter({ !$0.hasPrefix(".") }).sorted() {
        let n = try cut(raw.appending(path: sku), to: out.appending(path: sku))
        print("\(sku): \(n) cutouts")
        total += n
    }
    print("\(total) cutouts -> data/cutouts")
}
