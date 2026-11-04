import XCTest
import CoreLocation
import simd
@testable import AudioGhost

/// §6.3 ritual gates and §6.4 course-based correction / cold-start seeding.
final class CalibrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Tuning.resetOverrides()
    }

    // MARK: Ritual solver

    private func samples(_ value: Double, count: Int = 40, jitter: Double = 0) -> [Double] {
        (0..<count).map { value + (Double($0 % 2) * 2 - 1) * jitter }
    }

    func testRitualComputesOffsetAsHeadingMinusAttitude() {
        let heading = (90.0).radians
        let attitude = (20.0).radians
        let result = CalibrationService.solveRitual(headings: samples(heading),
                                                    headingAccuracies: samples(5),
                                                    attitudeYaws: samples(attitude))
        guard case .success(let offset) = result else { return XCTFail("expected success") }
        XCTAssertEqual(offset, (70.0).radians, accuracy: 1e-9)
        // And the offset does what it claims: attitude + offset == heading.
        XCTAssertEqual(wrapToPi(attitude + offset), heading, accuracy: 1e-9)
    }

    func testRitualAveragesOnTheCircle() {
        // 359° and 1° must average to 0°, not 180°.
        let headings = [(359.0).radians, (1.0).radians, (359.5).radians, (0.5).radians, 0.0]
        let result = CalibrationService.solveRitual(headings: headings,
                                                    headingAccuracies: samples(5, count: 5),
                                                    attitudeYaws: samples(0, count: 5))
        guard case .success(let offset) = result else { return XCTFail("expected success") }
        XCTAssertEqual(offset, 0, accuracy: 0.01)
    }

    func testRitualRejectsTooFewSamples() {
        let result = CalibrationService.solveRitual(headings: [0, 0],
                                                    headingAccuracies: [5, 5],
                                                    attitudeYaws: [0, 0])
        XCTAssertEqual(result.failure, .notEnoughSamples)
    }

    func testRitualRejectsNegativeHeadingAccuracy() {
        var accuracies = samples(5)
        accuracies[3] = -1                                   // iOS: "needs calibration"
        let result = CalibrationService.solveRitual(headings: samples(0),
                                                    headingAccuracies: accuracies,
                                                    attitudeYaws: samples(0))
        XCTAssertEqual(result.failure, .compassNeedsCalibration)
    }

    func testRitualRejectsInaccurateCompass() {
        let result = CalibrationService.solveRitual(headings: samples(0),
                                                    headingAccuracies: samples(25),
                                                    attitudeYaws: samples(0))
        XCTAssertEqual(result.failure, .compassInaccurate(25))
    }

    func testRitualRejectsMovementDuringMeasurement() {
        // Heading spread of ±10° is beyond the 5° gate.
        let result = CalibrationService.solveRitual(headings: samples(0, jitter: (10.0).radians),
                                                    headingAccuracies: samples(5),
                                                    attitudeYaws: samples(0))
        guard case .userMoved = result.failure else {
            return XCTFail("expected .userMoved, got \(String(describing: result.failure))")
        }
    }

    func testRitualAcceptsSmallJitter() {
        let result = CalibrationService.solveRitual(headings: samples(1.0, jitter: (2.0).radians),
                                                    headingAccuracies: samples(8),
                                                    attitudeYaws: samples(0.5, jitter: (1.0).radians))
        guard case .success = result else { return XCTFail("small jitter must pass the gates") }
    }

    /// Regression test for the ritual failing with `.notEnoughSamples` however still the user held
    /// the phone: CoreLocation's default `headingFilter` is 1°, so it only reports once the
    /// heading has *changed* by more than that. Standing still — which the ritual explicitly asks
    /// for — starved the sample window. The ritual must take every update.
    func testHeadingUpdatesAreUnfiltered() {
        let service = LocationService(queue: DispatchQueue(label: "test"))
        service.startHeading()
        XCTAssertEqual(service.headingFilter, kCLHeadingFilterNone,
                       "a non-zero heading filter starves the calibration ritual")
        service.stopHeading()
    }

    func testRitualNeedsOnlyFiveConcurrentSamples() {
        // The boundary the flow's collection window is written against.
        let result = CalibrationService.solveRitual(headings: samples(0.4, count: 5),
                                                    headingAccuracies: samples(6, count: 5),
                                                    attitudeYaws: samples(0.1, count: 5))
        guard case .success = result else { return XCTFail("five samples must be enough") }
        XCTAssertEqual(CalibrationService.solveRitual(headings: samples(0.4, count: 4),
                                                      headingAccuracies: samples(6, count: 4),
                                                      attitudeYaws: samples(0.1, count: 4)).failure,
                       .notEnoughSamples)
    }

    // MARK: Applying and invalidating

    func testApplyPreciseOffsetMakesCalibrationValid() {
        let service = CalibrationService()
        XCTAssertFalse(service.isValid)
        XCTAssertEqual(service.yawOffset, 0, "audio still renders while uncalibrated")
        service.applyPreciseOffset(0.5)
        XCTAssertEqual(service.quality, .precise)
        XCTAssertEqual(service.yawOffset, 0.5, accuracy: 1e-12)
        service.invalidate()
        XCTAssertEqual(service.quality, .none)
        XCTAssertFalse(service.isValid)
    }

    // MARK: Course correction (§6.4)

    private func fix(speed: Double, courseDeg: Double, courseAccuracy: Double = 10,
                     enu: SIMD3<Double> = .zero, t: TimeInterval = 0) -> SmoothedFix {
        let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)
        let raw = RawFix(coordinate: origin, horizontalAccuracy: 5, speed: speed,
                         course: courseDeg, courseAccuracy: courseAccuracy, timestamp: t)
        return SmoothedFix(origin: origin, rawENU: enu, smoothedENU: enu, velocityENU: .zero, raw: raw)
    }

    func testCourseIgnoredBelowMinimumSpeed() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        XCTAssertEqual(service.updateWithCourse(fix: fix(speed: 0.3, courseDeg: 90),
                                                attitudeYawNow: 0), .ignoredSlow)
        XCTAssertEqual(service.yawOffset, 0)
    }

    func testCourseIgnoredWhenCourseAccuracyIsBad() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        XCTAssertEqual(service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 90, courseAccuracy: 40),
                                                attitudeYawNow: 0), .ignoredCourseAccuracy)
        XCTAssertEqual(service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 90, courseAccuracy: -1),
                                                attitudeYawNow: 0), .ignoredCourseAccuracy)
    }

    func testCourseGateRejectsHeadTurns() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        // Walking north while looking 80° to the side: beyond the 60° gate.
        let update = service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 0),
                                              attitudeYawNow: (80.0).radians)
        guard case .ignoredHeadTurned = update else { return XCTFail("expected the gate to fire") }
        XCTAssertEqual(service.yawOffset, 0, "a glance must not corrupt the offset")
    }

    func testCourseCorrectsSlowlyTowardsTruth() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        // Head yaw reads 10° while the user actually walks due north: 10° of drift to remove.
        let drift = (10.0).radians
        for i in 0..<200 {
            _ = service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 0, t: Double(i)),
                                         attitudeYawNow: drift)
        }
        XCTAssertEqual(service.yawOffset, -drift, accuracy: (0.5).radians)
        XCTAssertEqual(service.quality, .precise, "drift correction must not downgrade quality")
    }

    func testCourseGainMatchesTheSpec() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        let err = (10.0).radians
        _ = service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 0), attitudeYawNow: err)
        // One fix moves the offset by gain × error.
        XCTAssertEqual(service.yawOffset, -Tuning.current.courseGain * err, accuracy: 1e-12)
        XCTAssertEqual(service.lastCourseError ?? 0, -err, accuracy: 1e-12)
    }

    func testColdStartSeedsCoarseAfterFifteenMetres() {
        let service = CalibrationService()
        XCTAssertFalse(service.isValid)
        var update = service.updateWithCourse(
            fix: fix(speed: 1.4, courseDeg: 90, enu: SIMD3(0, 0, 0), t: 0), attitudeYawNow: 0.2)
        guard case .accumulating = update else { return XCTFail("expected accumulation") }
        XCTAssertFalse(service.isValid, "one fix is not a walk")

        // Walk 20 m east.
        update = service.updateWithCourse(
            fix: fix(speed: 1.4, courseDeg: 90, enu: SIMD3(20, 0, 0), t: 1), attitudeYawNow: 0.2)
        guard case .seededCoarse(let offset) = update else {
            return XCTFail("expected a coarse seed, got \(update)")
        }
        XCTAssertEqual(service.quality, .coarse)
        XCTAssertEqual(wrapToPi(0.2 + offset), (90.0).radians, accuracy: 1e-9,
                       "seeded offset must make trueYaw equal the course")
    }

    func testColdStartResetsAccumulationWhenTheUserStops() {
        let service = CalibrationService()
        _ = service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 90, enu: .zero, t: 0),
                                     attitudeYawNow: 0)
        _ = service.updateWithCourse(fix: fix(speed: 0.1, courseDeg: 90, enu: SIMD3(10, 0, 0), t: 1),
                                     attitudeYawNow: 0)
        // After stopping, the accumulated distance restarts from the next moving fix.
        let update = service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 90, enu: SIMD3(20, 0, 0), t: 2),
                                              attitudeYawNow: 0)
        guard case .accumulating(let walked) = update else {
            return XCTFail("expected accumulation to restart, got \(update)")
        }
        XCTAssertEqual(walked, 0, accuracy: 1e-9)
    }

    func testRecalibrationHintFiresOnSustainedError() {
        let service = CalibrationService()
        service.applyPreciseOffset(0)
        XCTAssertFalse(service.suggestsRecalibration)
        _ = service.updateWithCourse(fix: fix(speed: 1.4, courseDeg: 0), attitudeYawNow: (40.0).radians)
        XCTAssertTrue(service.suggestsRecalibration)
    }
}

private extension Result where Success == Double, Failure == CalibrationError {
    var failure: CalibrationError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
