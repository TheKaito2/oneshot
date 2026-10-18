// Product pictures from packshots: cuts each <sku>.jpg|png out of its background (Vision foreground mask, every
// instance kept so a pack with a loose piece stays whole) and writes OneShot/Resources/Seed/product-<sku>.png,
// cropped to the pack, longest side 512 px, transparent around it.
// Exception: KitKat's white logo oval was masked out as background (18 Oct). Its PNG is cut instead by flood-filling
// near-white (≥ 242) from the image corners, so only white touching the border goes transparent.
// Build: swiftc -O tools/packshots.swift -o build/packshots
// Run:   build/packshots <folder of <sku>.jpg|png> OneShot/Resources/Seed
import CoreImage
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: packshots <source folder> <dest folder>")
    exit(2)
}
let source = URL(fileURLWithPath: args[1]), dest = URL(fileURLWithPath: args[2])
let context = CIContext()
let names = try FileManager.default.contentsOfDirectory(atPath: source.path())
    .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
for name in names {
    let url = source.appending(path: name)
    let sku = String(name.dropLast(4))
    let handler = VNImageRequestHandler(url: url)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let result = request.results?.first else {
        print("\(sku): no foreground found, skipped")
        continue
    }
    let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
    var cut = CIImage(cvPixelBuffer: buffer)
    let scale = min(1, 512 / max(cut.extent.width, cut.extent.height))
    cut = cut.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let file = dest.appending(path: "product-\(sku).png")
    try context.writePNGRepresentation(of: cut, to: file, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("\(sku): \(result.allInstances.count) instance(s), \(Int(cut.extent.width))x\(Int(cut.extent.height))")
}
