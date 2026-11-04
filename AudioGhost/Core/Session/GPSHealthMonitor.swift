import Foundation

/// Decides when the heartbeat should send a GPS complaint or a recovery to the reducer (§8.1).
///
/// Pure value type: no clock, no queue. `SessionCoordinator` owns one on `trackingQueue` and
/// feeds it the time, the latest fix and whether the reducer can currently act on a complaint.
///
/// It remembers which complaint the reducer has actually been sent (`delivered`), so each
/// complaint is sent exactly once rather than at the 25 Hz heartbeat rate. Two rules matter:
///   * Nothing is recorded as delivered while `canDeliver` is false (`.awaitingCalibration`,
///     where the reducer ignores GPS complaints). The weak-fix timer still runs, so a weak spell
///     that began before calibration fires as soon as the session is running.
///   * `.accuracyPoor` can escalate to `.gpsLost`, matching the reducer's
///     `(.degraded(.accuracyPoor), .gpsWentStale)` transition. `.gpsLost` never downgrades.
struct GPSHealthMonitor {

    /// The complaint the reducer has been sent and not yet told has cleared.
    private(set) var delivered: DegradedReason?
    /// Start of the current run of weak fixes, or nil if the latest fix was strong.
    private(set) var poorAccuracySince: TimeInterval?

    mutating func reset() {
        delivered = nil
        poorAccuracySince = nil
    }

    /// Heartbeat check against the latest accepted fix. Returns the event to send, if any.
    mutating func check(now: TimeInterval,
                        fixTimestamp: TimeInterval,
                        horizontalAccuracy: Double,
                        canDeliver: Bool,
                        tuning: Tuning = .current) -> SessionEvent? {
        if now - fixTimestamp > tuning.gpsStaleTimeout {
            guard canDeliver, delivered != .gpsLost else { return nil }
            delivered = .gpsLost
            return .gpsWentStale
        }

        guard horizontalAccuracy > tuning.weakAccuracy else {
            poorAccuracySince = nil
            return nil
        }
        if poorAccuracySince == nil { poorAccuracySince = now }
        if let since = poorAccuracySince, now - since > tuning.accuracyPoorTimeout,
           canDeliver, delivered == nil {
            delivered = .accuracyPoor
            return .gpsAccuracyPoor
        }
        return nil
    }

    /// Every accepted fix. Only a *strong* fix clears a complaint: a stream of weak ones is
    /// exactly what `.accuracyPoor` is complaining about, so it must not clear itself.
    mutating func fixAccepted(horizontalAccuracy: Double, tuning: Tuning = .current) -> SessionEvent? {
        guard horizontalAccuracy <= tuning.weakAccuracy else { return nil }
        poorAccuracySince = nil
        guard delivered != nil else { return nil }
        delivered = nil
        return .gpsRecovered
    }
}
