import Foundation
import MetricKit

/// Crash, hang and disk-write reports from iOS (MetricKit), kept as JSON in Documents/Diagnostics so the owner can
/// share them from Settings. Apple's own, on the device: no third-party SDK, nothing sent anywhere by OneShot.
/// iOS delivers them at most once a day, for the day before (immediately on iOS 15+ for crashes, on the next launch).
final class Diagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = Diagnostics()
    static let folder = URL.documentsDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
    /// A month of reports is plenty to share; older ones are deleted.
    private static let keep = 30

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            for payload in payloads {
                let stamp = payload.timeStampEnd.formatted(.iso8601.timeSeparator(.omitted))
                try payload.jsonRepresentation().write(to: Self.folder.appending(path: "diagnostic-\(stamp).json"), options: .atomic)
            }
            for old in Self.files().dropFirst(Self.keep) { try FileManager.default.removeItem(at: old) }
        } catch {
            Log.error("diagnostics not saved: \(error)")
        }
    }

    /// Newest first.
    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
