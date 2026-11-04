import Foundation
import os

/// Minimal logging shim so call sites stay short and every subsystem string is spelled once.
enum Log {
    private static let logger = Logger(subsystem: "com.audioghost.AudioGhost", category: "app")

    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
