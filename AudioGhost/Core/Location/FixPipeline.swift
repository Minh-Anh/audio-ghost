import Foundation
import simd

/// The per-fix acceptance + smoothing pipeline of spec §5.3. Every location source — real, scripted
/// or replayed — pushes `RawFix`es in here and nothing else, so a desk simulation exercises
/// *exactly* the code path a field walk does. One that skipped the filter would prove nothing.
///
/// Tracking queue only: both `ingest` and every reader run there, so no lock is needed.
final class FixPipeline {

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

    var onFix: ((SmoothedFix) -> Void)?
    var onRejected: ((Rejection) -> Void)?

    /// The newest accepted fix.
    private(set) var latest: SmoothedFix?
    /// The session's ENU origin: the first accepted fix.
    private(set) var origin: Geo.Coordinate?
    private(set) var acceptedCount = 0
    private(set) var rejectedCount = 0

    private let filter: PositionFilter

    init(filter: PositionFilter = ExponentialPositionFilter()) {
        self.filter = filter
    }

    /// Forgets the origin and filter state; the next accepted fix seeds a new origin.
    func reset() {
        origin = nil
        latest = nil
        acceptedCount = 0
        rejectedCount = 0
        filter.reset()
    }

    /// Runs one raw fix through the gates and the filter, updates the counters and `latest`, and
    /// fires `onFix` or `onRejected`. The result is also returned, for tests.
    @discardableResult
    func ingest(_ fix: RawFix, now: TimeInterval = AppClock.now) -> Result<SmoothedFix, Rejection> {
        let result = evaluate(fix, now: now)
        switch result {
        case .success(let smoothed):
            latest = smoothed
            acceptedCount += 1
            onFix?(smoothed)
        case .failure(let rejection):
            rejectedCount += 1
            onRejected?(rejection)
        }
        return result
    }

    private func evaluate(_ fix: RawFix, now: TimeInterval) -> Result<SmoothedFix, Rejection> {
        if fix.horizontalAccuracy < 0 { return .failure(.invalidAccuracy) }
        if fix.horizontalAccuracy > Tuning.current.maxAcceptableAccuracy {
            return .failure(.poorAccuracy(fix.horizontalAccuracy))
        }
        let age = abs(now - fix.timestamp)
        if age > Tuning.current.maxFixAge { return .failure(.stale(age)) }

        let origin = self.origin ?? fix.coordinate
        self.origin = origin

        let rawENU = Geo.enu(of: fix.coordinate, origin: origin)
        let outcome = filter.update(rawENU: rawENU, accuracy: fix.horizontalAccuracy, time: fix.timestamp)
        guard outcome != .heldAsOutlier else { return .failure(.teleportCandidate) }

        return .success(SmoothedFix(origin: origin,
                                    rawENU: rawENU,
                                    smoothedENU: filter.position,
                                    velocityENU: filter.velocity,
                                    raw: fix))
    }
}
