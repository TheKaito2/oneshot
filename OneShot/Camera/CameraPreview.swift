import AVFoundation
import SwiftUI

/// Live camera preview, turned with the screen: upright in portrait and in landscape.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called on main with each new preview rotation angle.
    let onAngle: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.onAngle = onAngle
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onAngle: ((CGFloat) -> Void)?
    private var angle: CGFloat?

    // The camera follows the screen, not gravity: held flat over the counter, the horizon-level angle
    // (AVCaptureDevice.RotationCoordinator) guessed from the tilt and could turn the feed sideways on a portrait
    // screen (Krist, 22 Oct). Rotation relayouts the view, so this catches every turn of the iPad too.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else { return }
        let angle: CGFloat = switch orientation {
        case .landscapeRight: 0     // home side on the right: the back camera's native landscape
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        default: 90                 // portrait
        }
        guard angle != self.angle, let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        self.angle = angle
        onAngle?(angle)
    }
}
