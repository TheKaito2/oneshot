import os

/// The app's log, in Console.app and sysdiagnose under the subsystem `com.krist.oneshot`. Messages are public:
/// they hold timings, counts, file names and error descriptions, never a customer's or the shop's data.
enum Log {
    private static let logger = Logger(subsystem: "com.krist.oneshot", category: "app")

    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
