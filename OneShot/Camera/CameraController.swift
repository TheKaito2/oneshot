import AVFoundation
import CoreImage
import Observation
import os

/// Owns the capture session. Frames stay on `videoQueue`; SwiftUI only ever sees small values like `fps`.
/// Sendable by queue discipline: published values change on main, the session on `sessionQueue`,
/// counters, the detector and `latestFrame` on `videoQueue`; `orientation` is locked.
@Observable
final class CameraController: NSObject, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case running(AVCaptureDevice)
        case denied
        case failed(String)
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var state: State = .idle
    private(set) var fps = 0.0
    private(set) var boxes: [Box] = []
    /// Upright size of the frame `boxes` came from.
    private(set) var frameSize = CGSize(width: 1080, height: 1920)
    private(set) var detectMs = 0.0
    private(set) var detectorError: String?

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "oneshot.camera.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "oneshot.camera.video")
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let orientation = OSAllocatedUnfairLock(initialState: CGImagePropertyOrientation.up)
    /// Width / height of the scan zone. The preview fills the zone (aspect fill), so this is the part of the frame on screen.
    @ObservationIgnored private let visibleAspect = OSAllocatedUnfairLock<CGFloat?>(initialState: nil)
    // Touched only on videoQueue.
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var windowStart = CACurrentMediaTime()
    @ObservationIgnored private var detector: Detector?
    @ObservationIgnored private var lastDetect = 0.0
    @ObservationIgnored private var window = DetectWindow()
    @ObservationIgnored private var latestFrame: CVPixelBuffer?
    @ObservationIgnored private var smoother = BoxSmoother()
    @ObservationIgnored private let ciContext = CIContext()

    /// Detection stats for the current one-second window.
    private struct DetectWindow {
        var detects = 0
        var msSum = 0.0
        var msMax = 0.0
        var boxes = 0
    }

    /// Every other frame at 30 fps (15 Hz). Exactly 1/15 s sits on the frame spacing, so jitter skipped to every third frame.
    private static let detectInterval = 0.06
    /// The detector returns boxes down to `lockFloor` for the Resolver; live view shows only `liveFloor` and up.
    /// Measured 18 Oct (detector v2, tools/grade.py --floor): 0.1 -> 0.25 cut yellows from 11 to 3 on the 42-photo exam
    /// and from 16 to 11 on the unknown-item photos, with nothing lost. Every box under 0.25 was junk or a duplicate,
    /// and phones still turn yellow. Packs the detector misses still reach the Resolver through the Splitter.
    private static let lockFloor = 0.25
    private static let liveFloor: Float = 0.25

    /// Fed from the scan zone's size, so a lock bills what the cashier sees and nothing past the zone's edges.
    func setVisibleAspect(_ aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0 else { return }
        visibleAspect.withLock { $0 = aspect }
    }

    /// Fed from the preview's rotation, so the model sees the frame the way the screen shows it.
    func setPreviewAngle(_ angle: CGFloat) {
        orientation.withLock { $0 = CGImagePropertyOrientation(rotationAngle: angle) }
    }

    @MainActor
    func start() async {
        guard state == .idle else { return }
        // Load the model whatever the camera does: photo billing works even with no camera or access denied.
        videoQueue.async { self.loadDetector() }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .denied
            return
        }
        do {
            let device = try await withCheckedThrowingContinuation { continuation in
                sessionQueue.async {
                    do {
                        let device = try self.configure()
                        self.session.startRunning()
                        continuation.resume(returning: device)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            state = .running(device)
            logInterruptions()
        } catch let failure as Failure {
            state = .failed(failure.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Runs on sessionQueue.
    private func configure() throws -> AVCaptureDevice {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw Failure(message: String(localized: "No back camera found."))
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure(message: String(localized: "Can't use the camera input.")) }
        session.addInput(input)

        // Drop frames that arrive while the last one is still being handled, so the preview never lags.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw Failure(message: String(localized: "Can't read camera frames.")) }
        session.addOutput(videoOutput)
        return device
    }

    /// Freezes the newest frame upright and detects on it at the low floor. Runs on videoQueue, between live frames.
    func lock() async throws -> (image: CGImage, boxes: [Box]) {
        try await onVideoQueue {
            guard let detector = self.detector else {
                throw Failure(message: String(localized: "The camera is still starting. Try again in a second."))
            }
            let image = try self.uprightFrame()
            return (image, try detector.detect(image))
        }
    }

    /// Frees the camera for the barcode scanner, and saves power while a bill is open. The kept frame is dropped
    /// so a lock right after `resume()` can never bill a stale picture.
    /// The clear is queued after stopRunning returns, so a frame delivered during the stop can't survive it (a quick
    /// Scan more used to bill the previous frame's items a second time).
    func pause() {
        sessionQueue.async {
            self.session.stopRunning()
            self.videoQueue.async {
                self.latestFrame = nil
                self.smoother = BoxSmoother()   // boxes from before the pause would otherwise pop back
            }
        }
        boxes = []
    }

    func resume() {
        sessionQueue.async {
            if !self.session.isRunning, !self.session.inputs.isEmpty { self.session.startRunning() }
        }
    }

    /// Detects on an upright still photo (upload), on videoQueue like the lock.
    func detect(_ image: CGImage) async throws -> [Box] {
        try await onVideoQueue {
            guard let detector = self.detector else {
                throw Failure(message: String(localized: "The camera is still starting. Try again in a second."))
            }
            return try detector.detect(image)
        }
    }

    /// The newest frame, upright, without detection (quick-add shots).
    func freeze() async throws -> CGImage {
        try await onVideoQueue { try self.uprightFrame() }
    }

    private func onVideoQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            videoQueue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Runs on videoQueue.
    private func uprightFrame() throws -> CGImage {
        guard let frame = latestFrame else {
            throw Failure(message: String(localized: "The camera is still starting. Try again in a second."))
        }
        let upright = CIImage(cvPixelBuffer: frame).oriented(orientation.withLock { $0 })
        // What you see is what you bill: the preview crops the frame to the zone, so the lock does too. Billing the
        // full frame used to box packs past the zone's edges, and the frozen frame shrank into a letterbox.
        let shown = visibleAspect.withLock { $0 }.map { Self.centred(aspect: $0, in: upright.extent) } ?? upright.extent
        guard let image = ciContext.createCGImage(upright, from: shown) else {
            throw Failure(message: String(localized: "Couldn't freeze the camera frame."))
        }
        return image
    }

    /// The largest rect of `aspect` (width / height) centred in `extent`, on whole pixels: what aspect fill shows.
    static func centred(aspect: CGFloat, in extent: CGRect) -> CGRect {
        let width = min(extent.width, extent.height * aspect), height = width / aspect
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height).integral
            .intersection(extent)
    }

    /// Camera stalls show up in the console with their cause (multitasking, another app, thermal…).
    private func logInterruptions() {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            print("camera interrupted reason=\(raw)")  // AVCaptureSession.InterruptionReason raw value
        }
        _ = center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
            print("camera interruption ended")
        }
        _ = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            print("camera runtime error \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]))")
        }
    }

    /// Runs on videoQueue. The first load compiles the model for this device, so it stays off the session queue.
    private func loadDetector() {
        do {
            detector = try Detector(floor: Self.lockFloor)
        } catch {
            publishDetectorError(error)
        }
    }

    private func publishDetectorError(_ error: Error) {
        let text = "Detector: \(error.localizedDescription)"
        DispatchQueue.main.async { self.detectorError = text }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        countFrame(at: now)
        // Holding one buffer from the capture pool is fine; the lock copies it out before using it.
        latestFrame = sampleBuffer.imageBuffer

        // ponytail: detection runs inline on videoQueue, so frames arriving meanwhile are dropped
        // (alwaysDiscardsLateVideoFrames). That is the one-frame-in-flight gate; no flag needed.
        guard let detector, now - lastDetect >= Self.detectInterval, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastDetect = now
        let orientation = orientation.withLock { $0 }
        do {
            let boxes = smoother.update(try detector.detect(pixelBuffer, orientation: orientation).filter { $0.confidence >= Self.liveFloor })
            let ms = (CACurrentMediaTime() - now) * 1000
            window.detects += 1
            window.msSum += ms
            window.msMax = max(window.msMax, ms)
            window.boxes = boxes.count
            let size = orientation.uprightSize(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
            DispatchQueue.main.async {
                self.boxes = boxes
                self.frameSize = size
                self.detectMs = ms
            }
        } catch {
            // One bad frame is skipped. Only a model that fails to load disables Ring up (it used to stay off until relaunch).
            print("live detect failed: \(error)")
        }
    }

    private func countFrame(at now: CFTimeInterval) {
        frameCount += 1
        guard now - windowStart >= 1 else { return }
        let value = Double(frameCount) / (now - windowStart)
        // Same numbers as the HUD, readable on the Mac with `devicectl device process launch --console`.
        let avg = window.detects > 0 ? window.msSum / Double(window.detects) : 0
        print(String(format: "hud fps=%.1f detects=%d detect_ms_avg=%.1f max=%.1f boxes=%d",
                     value, window.detects, avg, window.msMax, window.boxes))
        frameCount = 0
        windowStart = now
        window = DetectWindow()
        DispatchQueue.main.async { self.fps = value }
    }
}
