import Foundation

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
