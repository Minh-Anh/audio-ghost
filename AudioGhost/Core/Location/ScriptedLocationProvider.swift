import Foundation
import simd

/// Desk simulation (spec §11.2). Plays a hardcoded path relative to the ghost, with injectable
/// Gaussian noise and simulated `horizontalAccuracy`, through the *same* `FixPipeline` the real
/// service uses. Without this, every tuning iteration costs a field walk — it is not optional.
final class ScriptedLocationProvider: LocationProviding {

    enum Path: String, CaseIterable, Identifiable {
        case approach100      // walk in from 100 m at 1.4 m/s, then stop at 3 m
        case circle20         // 20 m radius circle around the ghost
        case flyBy            // pass 10 m abeam at walking speed
        case rotateInPlace30  // stand 30 m away (tests head tracking only)
        case gpsDropout       // approach with a 12 s signal loss and a 40 m teleport on return

        var id: String { rawValue }

        var title: String {
            switch self {
            case .approach100: return "Approach from 100 m"
            case .circle20: return "Circle, r = 20 m"
            case .flyBy: return "Fly-by, 10 m abeam"
            case .rotateInPlace30: return "Stand at 30 m"
            case .gpsDropout: return "Approach + GPS dropout"
            }
        }
    }

    /// Standard deviation of the injected horizontal noise, meters.
    var noiseSigma: Double = 4
    /// Reported accuracy, meters.
    var reportedAccuracy: Double = 8

    private let ghost: Geo.Coordinate
    private let path: Path
    private let queue: DispatchQueue
    private let pipeline: FixPipeline
    private var timer: DispatchSourceTimer?
    private var startTime: TimeInterval = 0

    init(ghost: Geo.Coordinate, path: Path, queue: DispatchQueue, pipeline: FixPipeline) {
        self.ghost = ghost
        self.path = path
        self.queue = queue
        self.pipeline = pipeline
    }

    func start() async throws {
        startTime = AppClock.now
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        Log.info("ScriptedLocationProvider started: \(path.rawValue)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Path evaluation

    /// Listener position in ENU meters relative to the ghost, at elapsed time `t`.
    private func listenerOffset(at t: Double) -> SIMD3<Double> {
        switch path {
        case .approach100, .gpsDropout:
            let d = max(3, 100 - 1.4 * t)
            return SIMD3(0, -d, 0)                       // approaching from the south
        case .circle20:
            let omega = 1.4 / 20.0                       // walking a 20 m circle
            let a = omega * t
            return SIMD3(20 * sin(a), 20 * cos(a), 0)
        case .flyBy:
            let x = -60 + 1.4 * t                        // west → east, 10 m north of the ghost
            return SIMD3(x, 10, 0)
        case .rotateInPlace30:
            return SIMD3(0, -30, 0)
        }
    }

    private func tick() {
        let now = AppClock.now
        let t = now - startTime

        // 12 s of nothing, then a fix that lands 40 m away — exercises the teleport counter.
        if path == .gpsDropout, t > 30, t < 42 { return }

        var offset = listenerOffset(at: t)
        if path == .gpsDropout, t >= 42, t < 45 {
            offset += SIMD3(40, 0, 0)
        }
        offset.x += gaussian() * noiseSigma
        offset.y += gaussian() * noiseSigma

        let velocity = listenerOffset(at: t) - listenerOffset(at: max(0, t - 1))
        let speed = Geo.horizontalLength(velocity)
        let isMoving = speed > 0.05
        var course = -1.0
        if isMoving {
            course = atan2Bearing(east: velocity.x, north: velocity.y).degrees
            if course < 0 { course += 360 }              // CoreLocation reports [0, 360)
        }

        pipeline.ingest(RawFix(coordinate: Geo.coordinate(fromENU: offset, origin: ghost),
                               horizontalAccuracy: reportedAccuracy,
                               speed: speed,
                               course: course,
                               courseAccuracy: isMoving ? 10 : -1,
                               timestamp: now),
                        now: now)
    }

    /// Box–Muller standard normal.
    private func gaussian() -> Double {
        let u1 = Double.random(in: 1e-9...1)
        let u2 = Double.random(in: 0...1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
