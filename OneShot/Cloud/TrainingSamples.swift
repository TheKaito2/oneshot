import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Network
import os
import UniformTypeIdentifiers
import Vision

/// "Help improve OneShot": with the owner's opt-in, each paid sale's counter photo (faces blurred on the device) and
/// its confirmed item boxes are kept for training OneShot's own models, and sent on Wi-Fi, at most 50 a day.
/// Off unless the owner turns it on (App Store 5.1.1/5.1.2, Thai PDPA); turning it off deletes what was sent.
enum TrainingSamples {
    static let optInKey = "training.optIn"
    static let askedKey = "training.asked"
    /// The policy text the owner agreed to (site/index.html, "Helping improve OneShot").
    static let policyVersion = "2026-10-22"
    static let dailyLimit = 50
    private static let queueLimit = 200

    static var isOn: Bool { UserDefaults.standard.bool(forKey: optInKey) }

    /// One confirmed item: its product and where it is, YOLO style (centre and size, 0…1, origin top-left).
    struct Box: Codable, Equatable {
        let sku: String
        let source: String
        let cx: Double, cy: Double, w: Double, h: Double
    }

    struct Sample: Codable {
        var version = 1
        let app: String
        let device: String
        /// The day only, in Thailand.
        let date: String
        let width: Int, height: Int
        let boxes: [Box]
    }

    /// The boxes the cashier confirmed by charging: this frame's green items (picks included), not the earlier frames'
    /// from Scan more (their boxes belong to another photo), and never a yellow one.
    static func boxes(in regions: [Region]) -> [Box] {
        regions.compactMap { region in
            guard !region.earlier, case .sure(let sku, let source) = region.verdict else { return nil }
            let r = region.rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            // Vision's origin is bottom-left; training files use top-left.
            return Box(sku: sku, source: "\(source)", cx: r.midX, cy: 1 - r.midY, w: r.width, h: r.height)
        }
    }

    // MARK: - On the device

    static var folder: URL { URL.documentsDirectory.appending(path: "Training", directoryHint: .isDirectory) }

    /// The photos waiting to go up, oldest first.
    static func waiting() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keeps a paid sale's photo for training, off the main thread. Does nothing unless opted in.
    @MainActor
    static func keep(_ scan: LockedScan) {
        guard isOn, Account.shared.isSignedIn else { return }
        let boxes = boxes(in: scan.regions)
        guard !boxes.isEmpty else { return }
        let image = scan.image
        Task.detached(priority: .background) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard waiting().count < queueLimit else { return }   // offline for weeks: stop, don't fill the phone
                let blurred = blurFaces(image)
                guard let jpeg = jpeg(blurred) else { return }
                let sample = Sample(app: appVersion, device: deviceModel, date: today, width: blurred.width,
                                    height: blurred.height, boxes: boxes)
                let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
                try JSONEncoder().encode(sample).write(to: folder.appending(path: "\(name).json"))
                try jpeg.write(to: folder.appending(path: "\(name).jpg"))   // last: a .jpg means its pair is complete
            } catch {
                Log.error("training sample: \(error)")
            }
        }
    }

    /// Turning it off: nothing waiting is ever sent.
    static func clearWaiting() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Privacy

    /// Every face in the photo pixellated before it's stored: customers and the cashier aren't what's being learned.
    static func blurFaces(_ image: CGImage) -> CGImage {
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            Log.error("face detection: \(error)")
        }
        let faces = request.results ?? []
        guard !faces.isEmpty else { return image }
        var output = CIImage(cgImage: image)
        let extent = output.extent
        for face in faces {
            // Vision and Core Image both put the origin bottom-left; a margin covers hair and the jaw line.
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
                .insetBy(dx: -face.boundingBox.width * extent.width * 0.25, dy: -face.boundingBox.height * extent.height * 0.25)
                .intersection(extent)
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = output.clampedToExtent()
            pixellate.scale = Float(max(box.width, box.height) / 6)
            pixellate.center = CGPoint(x: box.midX, y: box.midY)
            guard let blocks = pixellate.outputImage?.cropped(to: box) else { continue }
            output = blocks.composited(over: output)
        }
        return context.createCGImage(output, from: extent) ?? image
    }

    nonisolated(unsafe) private static let context = CIContext()   // CIContext is thread-safe

    /// JPEG with nothing but the pixels: no location, no device metadata.
    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static var today: String {
        Date.now.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "Asia/Bangkok")!).year().month().day())
    }

    // MARK: - Sending

    /// Wi-Fi (not a hotspot or mobile data): training photos never use the shop's data plan.
    static var onWiFi: Bool { network.withLock { $0 } }
    private static let network = OSAllocatedUnfairLock(initialState: false)
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            network.withLock { $0 = path.status == .satisfied && path.usesInterfaceType(.wifi) && !path.isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "training.network"))
        return monitor
    }()

    /// Starts watching the network (once, at launch).
    static func startWatching() { _ = monitor }

    /// How many may still go up today.
    static var sendableToday: Int {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "training.sentDay") == today else { return dailyLimit }
        return max(0, dailyLimit - defaults.integer(forKey: "training.sentToday"))
    }

    static func countSent() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "training.sentDay") != today {
            defaults.set(today, forKey: "training.sentDay")
            defaults.set(0, forKey: "training.sentToday")
        }
        defaults.set(defaults.integer(forKey: "training.sentToday") + 1, forKey: "training.sentToday")
        defaults.set(defaults.integer(forKey: "training.sentTotal") + 1, forKey: "training.sentTotal")
    }
}
