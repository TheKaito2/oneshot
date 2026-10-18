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

    /// `floor`: the lowest box confidence returned. Kept low so weak boxes reach the Resolver and turn yellow
    /// instead of vanishing.
    init(floor: Double) throws {
        guard let url = Bundle.main.url(forResource: "Detector", withExtension: "mlmodelc") else {
            throw Failure(errorDescription: "Detector.mlmodelc is missing from the app bundle.")
        }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: MLModelConfiguration()))
        model.featureProvider = Thresholds(confidence: floor)
        request = VNCoreMLRequest(model: model)
        // Letterbox like Ultralytics training does; a centre crop would cut items at the frame edges.
        request.imageCropAndScaleOption = .scaleFit
    }

    /// Synchronous; call from one queue at a time.
    func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [Box] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    /// Synchronous; call from one queue at a time. `image` must already be upright.
    func detect(_ image: CGImage) throws -> [Box] {
        try run(VNImageRequestHandler(cgImage: image, orientation: .up))
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
