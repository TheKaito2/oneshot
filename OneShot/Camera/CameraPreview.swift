import AVFoundation
import SwiftUI

/// Live camera preview that stays horizon-level as the iPad rotates.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice
    /// Called on main with each new preview rotation angle.
    let onAngle: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.device = device
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
    var device: AVCaptureDevice?
    var onAngle: ((CGFloat) -> Void)?

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    // The coordinator reports 0° for a layer outside a window, so start it once the view is on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, coordinator == nil, let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        // KVO updates arrive on the main queue (AVCaptureDevice.h).
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview   // read here: the coordinator isn't Sendable
            MainActor.assumeIsolated {
                guard let self, let connection = self.previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
                self.onAngle?(angle)
            }
        }
        self.coordinator = coordinator
    }
}
