import XCTest
import simd
@testable import AudioGhost

/// Regression tests for course seeding from a stale attitude yaw.
///
/// GPS keeps delivering fixes while the AirPods are out. `SessionCoordinator` used to pass the
/// last yaw from the old CoreMotion reference frame into `updateWithCourse` anyway, so 15 m of
/// walking seeded a `.coarse` offset that could be arbitrarily wrong. On reconnect the reducer
/// saw `.coarse` and skipped the calibration prompt. These tests drive
/// `SessionCoordinator.courseUpdate`, the gate the coordinator calls on every accepted fix.
final class CourseFreshnessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Tuning.resetOverrides()
    }

    private func fix(east: Double, courseDeg: Double = 90, t: TimeInterval) -> SmoothedFix {
        let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)
        let raw = RawFix(coordinate: origin, horizontalAccuracy: 5, speed: 1.4,
                         course: courseDeg, courseAccuracy: 10, timestamp: t)
        let enu = SIMD3<Double>(east, 0, 0)
        return SmoothedFix(origin: origin, rawENU: enu, smoothedENU: enu, velocityENU: .zero, raw: raw)
    }

    func testFixesWithoutAnyAttitudeSampleCannotSeedCoarse() {
        let service = CalibrationService()
        // 50 m east with no head sample this session: every update is skipped.
        for i in 0...10 {
            let update = SessionCoordinator.courseUpdate(
                calibration: service, fix: fix(east: Double(i) * 5, t: Double(i)),
                attitudeYaw: 1.0, attitudeTime: nil, now: Double(i))
            XCTAssertNil(update)
        }
        XCTAssertEqual(service.quality, .none)
    }

    func testFixesWithStaleAttitudeCannotSeedCoarse() {
        let service = CalibrationService()
        let lastSample: TimeInterval = 100
        let stale = Tuning.current.motionStaleTimeout + 0.1
        for i in 0...10 {
            let update = SessionCoordinator.courseUpdate(
                calibration: service, fix: fix(east: Double(i) * 5, t: lastSample + stale + Double(i)),
                attitudeYaw: 1.0, attitudeTime: lastSample, now: lastSample + stale + Double(i))
            XCTAssertNil(update)
        }
        XCTAssertEqual(service.quality, .none)
    }

    /// The field scenario end to end: calibrated, AirPods out, walk 40 m, AirPods back in.
    func testWalkingDisconnectedDoesNotSeedAndSeedingResumesFromZeroOnReconnect() {
        let service = CalibrationService()
        service.applyPreciseOffset(0.3)

        // Disconnect: the coordinator clears the attitude time; the reducer invalidates.
        service.invalidate()
        var t: TimeInterval = 0
        for east in stride(from: 0.0, through: 40.0, by: 5.0) {
            t += 1
            XCTAssertNil(SessionCoordinator.courseUpdate(
                calibration: service, fix: fix(east: east, t: t),
                attitudeYaw: 2.5,            // the old frame's last yaw
                attitudeTime: nil, now: t))
        }
        XCTAssertEqual(service.quality, .none, "must still need calibration on reconnect")

        // Reconnect: samples flow again, in a new frame where walking east reads yaw −0.4.
        let freshYaw = -0.4
        t += 1
        let first = SessionCoordinator.courseUpdate(
            calibration: service, fix: fix(east: 45, t: t),
            attitudeYaw: freshYaw, attitudeTime: t - 0.04, now: t)
        // The 45 m walked while disconnected must not count toward the seed.
        guard case .accumulating(let walked)? = first else {
            return XCTFail("expected accumulation to restart, got \(String(describing: first))")
        }
        XCTAssertEqual(walked, 0, accuracy: 1e-9)

        t += 1
        let second = SessionCoordinator.courseUpdate(
            calibration: service, fix: fix(east: 65, t: t),
            attitudeYaw: freshYaw, attitudeTime: t - 0.04, now: t)
        guard case .seededCoarse(let offset)? = second else {
            return XCTFail("expected a coarse seed, got \(String(describing: second))")
        }
        XCTAssertEqual(service.quality, .coarse)
        XCTAssertEqual(wrapToPi(freshYaw + offset), (90.0).radians, accuracy: 1e-9,
                       "the seed must come from the fresh yaw, not the old frame's")
    }

    func testFreshAttitudeAtTheTimeoutBoundaryStillUpdates() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        let update = SessionCoordinator.courseUpdate(
            calibration: service, fix: fix(east: 0, courseDeg: 0, t: 10),
            attitudeYaw: 0, attitudeTime: 10 - Tuning.current.motionStaleTimeout, now: 10)
        XCTAssertNotNil(update, "a sample exactly motionStaleTimeout old is still fresh")
    }
}
