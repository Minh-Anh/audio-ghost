import Foundation
import os

/// Minimal logging shim so call sites stay short and every subsystem string is spelled once.
enum Log {
    private static let logger = Logger(subsystem: "com.audioghost.AudioGhost", category: "app")

    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

/// One clock for the whole app.
///
/// CoreMotion timestamps are seconds since boot (`systemUptime`); CoreLocation timestamps are
/// wall-clock `Date`s. Mixing them silently produces "fix age = 1.7 billion seconds" bugs, so
/// every timestamp that reaches the fusion loop is converted to uptime seconds here.
enum AppClock {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func uptime(for date: Date) -> TimeInterval {
        now - Date().timeIntervalSince(date)
    }
}
