import CoreML
import ImageIO
import Vision

struct Guess: Sendable, Equatable {
    let label: String
    let confidence: Float
}

struct Box: Sendable, Equatable {
    /// Normalised to the upright frame, Vision space (origin bottom-left).
    let rect: CGRect
    /// Best first, at most 3.
    let guesses: [Guess]

    var label: String { guesses.first?.label ?? "?" }
    var confidence: Float { guesses.first?.confidence ?? 0 }
}

/// Wraps the bundled `Detector.mlmodelc`. Ultralytics and Create ML exports both decode as
/// `VNRecognizedObjectObservation`, so swapping models only swaps the file.
final class Detector {
    private struct Failure: LocalizedError { let errorDescription: String? }

    /// Feeds the model pipeline's optional `confidenceThreshold` input (both trainers' exports have one).
    private final class Thresholds: NSObject, MLFeatureProvider {
        let confidence: Double
        init(confidence: Double) { self.confidence = confidence }
        var featureNames: Set<String> { ["confidenceThreshold"] }
        func featureValue(for featureName: String) -> MLFeatureValue? {
            featureName == "confidenceThreshold" ? MLFeatureValue(double: confidence) : nil
        }
    }

    private let request: VNCoreMLRequest
    /// A model with a small input (Create ML: 299 transfer learning, 416 full network) rings up from the frame plus 4 tiles.
    let tiled: Bool

    /// `floor`: the lowest box confidence returned. Kept low so weak boxes reach the Resolver and turn yellow
    /// instead of vanishing.
    init(floor: Double) throws {
        guard let url = Bundle.main.url(forResource: "Detector", withExtension: "mlmodelc") else {
            throw Failure(errorDescription: "Detector.mlmodelc is missing from the app bundle.")
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly   // the simulator's GPU path aborts the app (see onCPUInSimulator)
        #endif
        let coreML = try MLModel(contentsOf: url, configuration: configuration)
        tiled = Self.inputSide(coreML) < 600
        let model = try VNCoreMLModel(for: coreML)
        model.featureProvider = Thresholds(confidence: floor)
        request = VNCoreMLRequest(model: model)
        request.onCPUInSimulator()
        // Letterbox like Ultralytics training does; a centre crop would cut items at the frame edges.
        request.imageCropAndScaleOption = .scaleFit
    }

    /// Synchronous; call from one queue at a time.
    func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [Box] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    /// Synchronous; call from one queue at a time. `image` must already be upright. The lock and still photos come
    /// here; with a tiled model it costs 5 passes (live detection stays one pass a frame).
    func detect(_ image: CGImage) throws -> [Box] {
        guard tiled else { return try run(VNImageRequestHandler(cgImage: image, orientation: .up)) }
        return try Self.tiles.flatMap { tile -> [Box] in
            guard let crop = image.cropping(to: Self.pixelRect(tile, width: image.width, height: image.height)) else { return [] }
            return Self.fromTile(try run(VNImageRequestHandler(cgImage: crop, orientation: .up)), tile)
        }
    }

    // MARK: - Tiles (pure; tools/grade runs the same)

    /// The model's square input side in pixels (640 for YOLO11n, 299 for Create ML transfer learning).
    static func inputSide(_ model: MLModel) -> Int {
        model.modelDescription.inputDescriptionsByName.values.compactMap { $0.imageConstraint?.pixelsWide }.first ?? 0
    }

    /// The whole frame, then 4 overlapping tiles of 60 % per side, normalised in Vision space (origin bottom-left).
    /// A 299 px model shrinks a 1280 px counter's packs to ~70 px and fragments them: measured 20 Oct, 3/42 exact
    /// bills on the exam. In a tile they reach it ~1.7× bigger, as tools/createml_tiles.py trained them.
    static let tiles: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        + [0.0, 0.4].flatMap { y in [0.0, 0.4].map { x in CGRect(x: x, y: y, width: 0.6, height: 0.6) } }

    /// A tile's boxes in frame coordinates. One touching an inside edge of the tile is a pack cut in two: dropped,
    /// because the whole pack is in the frame pass or a neighbouring tile (the tiles overlap by 20 % of the frame).
    static func fromTile(_ boxes: [Box], _ tile: CGRect, margin: CGFloat = 0.01) -> [Box] {
        boxes.compactMap { box in
            let r = box.rect
            let cut = (tile.minX > 0 && r.minX < margin) || (tile.maxX < 1 && r.maxX > 1 - margin)
                || (tile.minY > 0 && r.minY < margin) || (tile.maxY < 1 && r.maxY > 1 - margin)
            guard !cut else { return nil }
            return Box(rect: CGRect(x: tile.minX + r.minX * tile.width, y: tile.minY + r.minY * tile.height,
                                    width: r.width * tile.width, height: r.height * tile.height), guesses: box.guesses)
        }
    }

    /// Normalised Vision rect to pixels in a top-left image (like LockedScan.pixelRect).
    static func pixelRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h).integral
    }

    private func run(_ handler: VNImageRequestHandler) throws -> [Box] {
        try handler.perform([request])
        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.map { observation in
            Box(rect: observation.boundingBox,
                guesses: observation.labels.prefix(3).map { Guess(label: $0.identifier, confidence: $0.confidence) })
        }
    }
}

extension VNRequest {
    /// In the simulator, Vision's GPU (MPSGraph) backend throws a C++ exception on this macOS ("MpsGraph backend
    /// validation on incompatible OS"); out of the detector's `perform` it aborted the app (SIGABRT, 19 Oct).
    /// Only the detector uses this: FeaturePrint on the simulator's CPU returns identical vectors for every image,
    /// so the gallery is left to fail cleanly there (the detector alone names the demo tables).
    func onCPUInSimulator() {
        #if targetEnvironment(simulator)
        guard let stages = try? supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }
}

extension CGImagePropertyOrientation {
    /// Back camera: maps a connection rotation angle (0/90/180/270) to the EXIF orientation of the raw sensor frame.
    init(rotationAngle: CGFloat) {
        switch (Int(rotationAngle.rounded()) % 360 + 360) % 360 {
        case 90: self = .right
        case 180: self = .down
        case 270: self = .left
        default: self = .up
        }
    }

    /// Size of a `width × height` buffer once it is shown upright.
    func uprightSize(_ width: Int, _ height: Int) -> CGSize {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored: CGSize(width: height, height: width)
        default: CGSize(width: width, height: height)
        }
    }
}
