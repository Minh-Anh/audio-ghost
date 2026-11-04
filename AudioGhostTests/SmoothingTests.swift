import XCTest
import simd
@testable import AudioGhost

/// §5.3 smoothing, §5.5 interpolation freeze, §5.6 near-field clamp.
final class SmoothingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Tuning.resetOverrides()
    }

    // MARK: Exponential filter

    func testFirstFixSnaps() {
        let f = ExponentialPositionFilter()
        let outcome = f.update(rawENU: SIMD3(10, 20, 0), accuracy: 5, time: 100)
        XCTAssertEqual(outcome, .snapped)
        XCTAssertEqual(f.position.x, 10, accuracy: 1e-9)
        XCTAssertEqual(f.velocity, .zero)
    }

    func testTauScalesWithAccuracy() {
        // Same dt and same step: a good fix must move the estimate further than a poor one.
        func step(accuracy: Double) -> Double {
            let f = ExponentialPositionFilter()
            f.update(rawENU: .zero, accuracy: accuracy, time: 0)
            f.update(rawENU: SIMD3(10, 0, 0), accuracy: accuracy, time: 1)
            return f.position.x
        }
        let good = step(accuracy: 5)      // τ = tauMin
        let poor = step(accuracy: 30)     // τ = tauMax
        XCTAssertGreaterThan(good, poor)
        // Exact alpha for τ = 1 s, dt = 1 s.
        XCTAssertEqual(good, 10 * (1 - exp(-1.0)), accuracy: 1e-9)
        XCTAssertEqual(poor, 10 * (1 - exp(-1.0 / 3.0)), accuracy: 1e-9)
    }

    func testTauClampsBelowFiveAndAboveThirtyMetres() {
        func alpha(accuracy: Double) -> Double {
            let f = ExponentialPositionFilter()
            f.update(rawENU: .zero, accuracy: accuracy, time: 0)
            f.update(rawENU: SIMD3(1, 0, 0), accuracy: accuracy, time: 1)
            return f.position.x
        }
        XCTAssertEqual(alpha(accuracy: 1), alpha(accuracy: 5), accuracy: 1e-12)
        XCTAssertEqual(alpha(accuracy: 30), alpha(accuracy: 90), accuracy: 1e-12)
    }

    func testTeleportNeedsThreeConsecutiveFixesThenSnaps() {
        let f = ExponentialPositionFilter()
        f.update(rawENU: .zero, accuracy: 5, time: 0)
        let far = SIMD3<Double>(100, 0, 0)
        XCTAssertEqual(f.update(rawENU: far, accuracy: 5, time: 1), .heldAsOutlier)
        XCTAssertEqual(f.position.x, 0, accuracy: 1e-9, "estimate must not move on a suspect fix")
        XCTAssertEqual(f.update(rawENU: far, accuracy: 5, time: 2), .heldAsOutlier)
        XCTAssertEqual(f.update(rawENU: far, accuracy: 5, time: 3), .snapped)
        XCTAssertEqual(f.position.x, 100, accuracy: 1e-9)
        XCTAssertEqual(f.velocity, .zero, "velocity must not survive a teleport snap")
    }

    func testTeleportStreakResetsOnAGoodFix() {
        let f = ExponentialPositionFilter()
        f.update(rawENU: .zero, accuracy: 5, time: 0)
        f.update(rawENU: SIMD3(100, 0, 0), accuracy: 5, time: 1)
        f.update(rawENU: SIMD3(1, 0, 0), accuracy: 5, time: 2)          // plausible: streak resets
        f.update(rawENU: SIMD3(100, 0, 0), accuracy: 5, time: 3)
        f.update(rawENU: SIMD3(100, 0, 0), accuracy: 5, time: 4)
        XCTAssertLessThan(f.position.x, 50, "two suspect fixes must not be enough to snap")
    }

    func testVelocityIsClampedToWalkingSpeed() {
        let f = ExponentialPositionFilter()
        f.update(rawENU: .zero, accuracy: 5, time: 0)
        f.update(rawENU: SIMD3(19, 0, 0), accuracy: 5, time: 0.1)
        XCTAssertLessThanOrEqual(simd_length(f.velocity), Tuning.current.maxFixSpeed + 1e-9)
    }

    // MARK: Dead reckoning (§5.5)

    func testDeadReckoningFreezesAfterOnePointFiveSeconds() {
        let fix = SmoothedFix(origin: Geo.Coordinate(latitude: 0, longitude: 0),
                              rawENU: .zero,
                              smoothedENU: .zero,
                              velocityENU: SIMD3(1, 0, 0),
                              raw: RawFix(coordinate: Geo.Coordinate(latitude: 0, longitude: 0),
                                          horizontalAccuracy: 5, timestamp: 100))
        XCTAssertEqual(fix.predictedENU(at: 100.5).x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fix.predictedENU(at: 101.5).x, 1.5, accuracy: 1e-9)
        XCTAssertEqual(fix.predictedENU(at: 110).x, 1.5, accuracy: 1e-9, "extrapolation must freeze")
        XCTAssertEqual(fix.predictedENU(at: 99).x, 0, accuracy: 1e-9, "no backwards extrapolation")
    }

    // MARK: Rejection pipeline

    func testPipelineReportsThroughItsCallbacks() {
        let pipeline = FixPipeline()
        let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)
        var accepted = 0
        var rejections: [FixPipeline.Rejection] = []
        pipeline.onFix = { _ in accepted += 1 }
        pipeline.onRejected = { rejections.append($0) }

        pipeline.ingest(RawFix(coordinate: origin, horizontalAccuracy: 5, timestamp: 100), now: 100)
        pipeline.ingest(RawFix(coordinate: origin, horizontalAccuracy: -1, timestamp: 101), now: 101)

        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(rejections, [.invalidAccuracy])
        XCTAssertEqual(pipeline.acceptedCount, 1)
        XCTAssertEqual(pipeline.rejectedCount, 1)

        pipeline.reset()
        XCTAssertNil(pipeline.latest)
        XCTAssertNil(pipeline.origin)
        XCTAssertEqual(pipeline.acceptedCount, 0)
    }

    func testPipelineRejectsBadAccuracyAndStaleFixes() {
        let pipeline = FixPipeline()
        let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)
        func fix(accuracy: Double, t: TimeInterval) -> RawFix {
            RawFix(coordinate: origin, horizontalAccuracy: accuracy, timestamp: t)
        }
        XCTAssertEqual(pipeline.ingest(fix(accuracy: -1, t: 100), now: 100),
                       .failure(.invalidAccuracy))
        XCTAssertEqual(pipeline.ingest(fix(accuracy: 45, t: 100), now: 100),
                       .failure(.poorAccuracy(45)))
        if case .failure(let r) = pipeline.ingest(fix(accuracy: 5, t: 100), now: 200) {
            XCTAssertEqual(r, .stale(100))
        } else {
            XCTFail("a 100 s old fix must be rejected")
        }
        XCTAssertEqual(pipeline.rejectedCount, 3)
        XCTAssertEqual(pipeline.acceptedCount, 0)
    }

    func testPipelineSeedsOriginOnFirstAcceptedFix() {
        let pipeline = FixPipeline()
        let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)
        _ = pipeline.ingest(RawFix(coordinate: origin, horizontalAccuracy: 5, timestamp: 100), now: 100)
        XCTAssertEqual(pipeline.origin?.latitude, origin.latitude)
        // 10 m north of the origin, one second later — a plausible step, so it is accepted and
        // its ENU is measured against the seeded origin.
        let north = Geo.coordinate(fromENU: SIMD3(0, 10, 0), origin: origin)
        _ = pipeline.ingest(RawFix(coordinate: north, horizontalAccuracy: 5, timestamp: 101), now: 101)
        XCTAssertEqual(pipeline.latest?.rawENU.y ?? 0, 10, accuracy: 0.15)
        XCTAssertEqual(pipeline.acceptedCount, 2)
    }

    func testPipelineTreatsALargeJumpAsATeleportCandidate() {
        let pipeline = FixPipeline()
        let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)
        _ = pipeline.ingest(RawFix(coordinate: origin, horizontalAccuracy: 5, timestamp: 100), now: 100)
        let far = Geo.coordinate(fromENU: SIMD3(0, 100, 0), origin: origin)
        XCTAssertEqual(pipeline.ingest(RawFix(coordinate: far, horizontalAccuracy: 5, timestamp: 101),
                                       now: 101),
                       .failure(.teleportCandidate))
        XCTAssertEqual(pipeline.latest?.smoothedENU.y ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: Near-field clamp (§5.6)

    private func engineWithGhost(north: Double) -> SpatialAudioEngine {
        let engine = SpatialAudioEngine()
        engine.setGhostENU(SIMD3(0, north, 0))
        return engine
    }

    private func pose(at enu: SIMD3<Double>, accuracy: Double) -> ListenerPose {
        var p = ListenerPose.identity
        p.enuPosition = enu
        p.horizontalAccuracy = accuracy
        return p
    }

    func testClampEngagesInsideTheFloorAndHoldsDistance() {
        let engine = engineWithGhost(north: 30)
        _ = engine.updateListener(pose: pose(at: SIMD3(0, 0, 0), accuracy: 5), now: 0, frameConfig: FrameConfig())
        let state = engine.updateListener(pose: pose(at: SIMD3(0, 28, 0), accuracy: 5), now: 1, frameConfig: FrameConfig())
        XCTAssertTrue(state.clampActive, "2 m away with 5 m accuracy must clamp")
        XCTAssertEqual(state.trueDistance, 2, accuracy: 1e-6)
        XCTAssertEqual(state.renderedDistance, 5, accuracy: 1e-6, "held at max(floor, accuracy)")
    }

    func testClampRadiusFollowsGpsAccuracy() {
        let engine = engineWithGhost(north: 30)
        _ = engine.updateListener(pose: pose(at: .zero, accuracy: 20), now: 0, frameConfig: FrameConfig())
        let state = engine.updateListener(pose: pose(at: SIMD3(0, 25, 0), accuracy: 20), now: 1, frameConfig: FrameConfig())
        XCTAssertTrue(state.clampActive, "5 m away with 20 m accuracy is inside the noise")
        XCTAssertEqual(state.renderedDistance, 20, accuracy: 1e-6)
    }

    func testClampHysteresisPreventsBoundaryFlapping() {
        let engine = engineWithGhost(north: 30)
        _ = engine.updateListener(pose: pose(at: .zero, accuracy: 2), now: 0, frameConfig: FrameConfig())
        // Inside the 4 m floor → clamped.
        XCTAssertTrue(engine.updateListener(pose: pose(at: SIMD3(0, 27, 0), accuracy: 2), now: 1, frameConfig: FrameConfig()).clampActive)
        // 4.4 m out: past the floor but inside floor × 1.25 → must stay clamped.
        XCTAssertTrue(engine.updateListener(pose: pose(at: SIMD3(0, 25.6, 0), accuracy: 2), now: 2, frameConfig: FrameConfig()).clampActive)
        // 5.5 m out: past the exit threshold → releases.
        XCTAssertFalse(engine.updateListener(pose: pose(at: SIMD3(0, 24.5, 0), accuracy: 2), now: 3, frameConfig: FrameConfig()).clampActive)
    }

    func testClampKeepsTrueHeight() {
        let engine = SpatialAudioEngine()
        engine.setGhostENU(SIMD3(0, 0, 8))            // directly overhead, 8 m up
        _ = engine.updateListener(pose: pose(at: .zero, accuracy: 5), now: 0, frameConfig: FrameConfig())
        let state = engine.updateListener(pose: pose(at: .zero, accuracy: 5), now: 1, frameConfig: FrameConfig())
        XCTAssertTrue(state.clampActive)
        XCTAssertEqual(state.elevation, 8, accuracy: 1e-9, "height must survive the clamp")
    }

    /// The clamp's bearing low-pass must filter the *error* through `wrapToPi`: a target that
    /// crosses the ±π seam has to be approached the short way (10°), never the long way round
    /// through north (350°).
    func testClampBearingFilterIsWrapAware() {
        let engine = SpatialAudioEngine()
        engine.setGhostENU(.zero)

        // Listener 1 m north of the ghost ⇒ the ghost bears due south (±180°). Inside the 4 m
        // floor, so the clamp is engaged throughout.
        var state = engine.updateListener(pose: pose(at: SIMD3(0, 1, 0), accuracy: 5), now: 0, frameConfig: FrameConfig())
        XCTAssertTrue(state.clampActive)
        XCTAssertEqual(abs(state.renderedBearing), .pi, accuracy: 1e-9, "first tick seeds the truth")

        // Step slightly west: the true bearing becomes +170°, a 10° change across the seam.
        let target = atan2Bearing(east: 0.176, north: -1)
        XCTAssertGreaterThan(target, (170.0).radians)

        var bearings: [Double] = []
        for i in 1...40 {
            state = engine.updateListener(pose: pose(at: SIMD3(-0.176, 1, 0), accuracy: 5),
                                          now: Double(i), frameConfig: FrameConfig())
            bearings.append(state.renderedBearing)
        }
        for b in bearings {
            XCTAssertGreaterThan(abs(b), (150.0).radians,
                                 "filter swept through north instead of taking the short way")
        }
        XCTAssertEqual(bearings.last!, target, accuracy: 0.02, "and it converges on the truth")
    }

    func testNoClampOutsideTheFloor() {
        let engine = engineWithGhost(north: 100)
        _ = engine.updateListener(pose: pose(at: .zero, accuracy: 5), now: 0, frameConfig: FrameConfig())
        let state = engine.updateListener(pose: pose(at: .zero, accuracy: 5), now: 1, frameConfig: FrameConfig())
        XCTAssertFalse(state.clampActive)
        XCTAssertEqual(state.renderedDistance, 100, accuracy: 1e-9)
        XCTAssertEqual(state.bearing, 0, accuracy: 1e-9, "due north")
    }
}
