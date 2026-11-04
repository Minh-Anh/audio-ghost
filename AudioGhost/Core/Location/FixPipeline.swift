import Foundation
import simd

/// The per-fix acceptance + smoothing pipeline of spec §5.3, factored out of `LocationService`
/// so that the scripted and replay providers exercise *exactly* the same code path — a desk
/// simulation that skips the filter proves nothing.
final class FixPipeline {

    private let filter: PositionFilter
    private let lock = NSLock()
    private var _origin: Geo.Coordinate?
    private var _latest: SmoothedFix?

    private(set) var acceptedCount = 0
    private(set) var rejectedCount = 0

    init(filter: PositionFilter = ExponentialPositionFilter()) {
        self.filter = filter
    }

    var origin: Geo.Coordinate? {
        lock.lock(); defer { lock.unlock() }
        return _origin
    }

    var latest: SmoothedFix? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    func reset() {
        lock.lock()
        _origin = nil
        _latest = nil
        acceptedCount = 0
        rejectedCount = 0
        lock.unlock()
        filter.reset()
    }

    enum Rejection: Error, Equatable {
        case invalidAccuracy
        case poorAccuracy(Double)
        case stale(Double)
        case teleportCandidate

        var reason: String {
            switch self {
            case .invalidAccuracy: return "invalid accuracy"
            case .poorAccuracy(let a): return "accuracy \(Int(a)) m"
            case .stale(let s): return String(format: "stale %.1f s", s)
            case .teleportCandidate: return "teleport candidate"
            }
        }
    }

    /// Returns the accepted smoothed fix, or the reason it was rejected.
    func ingest(_ fix: RawFix, now: TimeInterval = AppClock.now) -> Result<SmoothedFix, Rejection> {
        if fix.horizontalAccuracy < 0 { return fail(.invalidAccuracy) }
        if fix.horizontalAccuracy > Tuning.maxAcceptableAccuracy {
            return fail(.poorAccuracy(fix.horizontalAccuracy))
        }
        let age = abs(now - fix.timestamp)
        if age > 5 { return fail(.stale(age)) }

        lock.lock()
        if _origin == nil { _origin = fix.coordinate }
        let origin = _origin!
        lock.unlock()

        let rawENU = Geo.enu(of: fix.coordinate, origin: origin)
        let outcome = filter.update(rawENU: rawENU, accuracy: fix.horizontalAccuracy, time: fix.timestamp)
        guard outcome != .heldAsOutlier else { return fail(.teleportCandidate) }

        let smoothed = SmoothedFix(origin: origin,
                                   rawENU: rawENU,
                                   smoothedENU: filter.position,
                                   velocityENU: filter.velocity,
                                   horizontalAccuracy: fix.horizontalAccuracy,
                                   timestamp: fix.timestamp,
                                   raw: fix,
                                   snapped: outcome == .snapped)
        lock.lock()
        _latest = smoothed
        acceptedCount += 1
        lock.unlock()
        return .success(smoothed)
    }

    private func fail(_ r: Rejection) -> Result<SmoothedFix, Rejection> {
        lock.lock(); rejectedCount += 1; lock.unlock()
        return .failure(r)
    }
}
