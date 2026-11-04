import Foundation
import simd

/// A raw GPS fix, decoupled from CoreLocation so scripted providers and replays can produce them.
struct RawFix: Equatable {
    var coordinate: Geo.Coordinate
    var horizontalAccuracy: Double      // meters; < 0 means invalid
    var speed: Double = -1              // m/s; < 0 means invalid
    var course: Double = -1             // degrees cw from true north; < 0 means invalid
    var courseAccuracy: Double = -1     // degrees; < 0 means invalid
    var timestamp: TimeInterval         // uptime seconds (see AppClock)

    var courseRadians: Double? {
        guard course >= 0 else { return nil }
        return wrapToPi(course.radians)
    }
}

/// The filtered position handed to the fusion loop.
struct SmoothedFix: Equatable {
    var origin: Geo.Coordinate
    var rawENU: SIMD3<Double>
    var smoothedENU: SIMD3<Double>
    var velocityENU: SIMD3<Double>
    var raw: RawFix

    var horizontalAccuracy: Double { raw.horizontalAccuracy }
    var timestamp: TimeInterval { raw.timestamp }

    /// Dead-reckoned position at `time` (spec §5.5). Extrapolation freezes after
    /// `deadReckonMax` so stale velocity cannot walk the listener away.
    func predictedENU(at time: TimeInterval) -> SIMD3<Double> {
        let age = max(0, time - timestamp)
        return smoothedENU + velocityENU * min(age, Tuning.current.deadReckonMax)
    }
}

enum FilterOutcome: Equatable {
    /// Fix folded into the smoothed estimate normally.
    case smoothed
    /// Filter snapped to the raw fix (first fix, or teleport recovery after signal loss).
    case snapped
    /// Fix looked like a teleport and was dropped; the estimate did not move.
    case heldAsOutlier
}

/// Swappable position filter (spec §5.3 — the 2D constant-velocity Kalman filter is the designed
/// upgrade path; it is deliberately NOT built for the MVP).
protocol PositionFilter: AnyObject {
    var position: SIMD3<Double> { get }
    var velocity: SIMD3<Double> { get }
    func reset()
    @discardableResult
    func update(rawENU: SIMD3<Double>, accuracy: Double, time: TimeInterval) -> FilterOutcome
}

/// Exponential smoothing with an accuracy-scaled time constant plus teleport recovery (§5.3).
final class ExponentialPositionFilter: PositionFilter {

    private(set) var position: SIMD3<Double> = .zero
    private(set) var velocity: SIMD3<Double> = .zero

    /// Nil until the first fix.
    private var lastTime: TimeInterval?
    private var teleportStreak = 0

    func reset() {
        position = .zero
        velocity = .zero
        lastTime = nil
        teleportStreak = 0
    }

    @discardableResult
    func update(rawENU: SIMD3<Double>, accuracy: Double, time: TimeInterval) -> FilterOutcome {
        guard let lastTime else { return snap(to: rawENU, time: time) }

        // Teleport check — three consecutive wild fixes mean the filter is wrong, not the GPS.
        if Geo.horizontalLength(rawENU - position) > Tuning.current.teleportDistance {
            teleportStreak += 1
            if teleportStreak >= Tuning.current.teleportCount {
                teleportStreak = 0
                return snap(to: rawENU, time: time)
            }
            // Suspect but not yet confirmed: ignore this fix entirely.
            return .heldAsOutlier
        }
        teleportStreak = 0

        // Exponential smoothing, τ scaled by reported accuracy.
        let dt = max(1e-3, time - lastTime)
        let previous = position
        let tau = Tuning.current.tauMin + (Tuning.current.tauMax - Tuning.current.tauMin)
            * clamp((accuracy - 5) / 25, 0, 1)
        let alpha = 1 - exp(-dt / max(1e-3, tau))
        position += (rawENU - position) * alpha

        // Velocity for per-tick interpolation, clamped to a walking-plausible speed.
        var v = (position - previous) / dt
        let speed = simd_length(v)
        if speed > Tuning.current.maxFixSpeed { v *= Tuning.current.maxFixSpeed / speed }
        velocity = v

        self.lastTime = time
        return .smoothed
    }

    private func snap(to rawENU: SIMD3<Double>, time: TimeInterval) -> FilterOutcome {
        position = rawENU
        velocity = .zero
        lastTime = time
        return .snapped
    }
}
