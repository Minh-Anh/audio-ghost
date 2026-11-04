import XCTest
@testable import AudioGhost

/// Appendix A contracts, exactly as written in the spec.
final class WrapMathTests: XCTestCase {

    func testWrapToPiTable() {
        XCTAssertEqual(wrapToPi(0), 0, accuracy: 1e-12)
        XCTAssertEqual(wrapToPi(.pi), -.pi, accuracy: 1e-12)          // spec: wrapToPi(π) == -π
        XCTAssertEqual(wrapToPi(-.pi), -.pi, accuracy: 1e-12)
        XCTAssertEqual(wrapToPi(3 * .pi / 2), -.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(wrapToPi(-3 * .pi / 2), .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(wrapToPi(2 * .pi + 0.3), 0.3, accuracy: 1e-12)
        XCTAssertEqual(wrapToPi(-2 * .pi - 0.3), -0.3, accuracy: 1e-12)
        XCTAssertEqual(wrapToPi(10 * .pi + 0.1), 0.1, accuracy: 1e-9)
    }

    func testWrapToPiIsIdempotent() {
        for i in -50...50 {
            let x = Double(i) * 0.37
            XCTAssertEqual(wrapToPi(wrapToPi(x)), wrapToPi(x), accuracy: 1e-12)
        }
    }

    func testCircularMeanWrapsAcrossZero() {
        let mean = circularMean([(359.0).radians, (1.0).radians])
        XCTAssertNotNil(mean)
        XCTAssertEqual(mean!, 0, accuracy: 1e-9)
    }

    func testCircularMeanOfNarrowCluster() {
        let angles = [88.0, 90.0, 92.0].map { $0.radians }
        XCTAssertEqual(circularMean(angles)!, (90.0).radians, accuracy: 1e-9)
    }

    func testCircularMeanUndefinedWhenSpreadAroundCircle() {
        // Four evenly spaced angles have a zero resultant: no meaningful mean.
        let angles = [0.0, 90.0, 180.0, 270.0].map { $0.radians }
        XCTAssertNil(circularMean(angles))
        XCTAssertNil(circularMean([]))
    }

    func testCircularSpread() {
        let angles = [358.0, 2.0].map { $0.radians }
        XCTAssertEqual(circularSpread(angles), (2.0).radians, accuracy: 1e-9)
    }

    func testLowpassAngleFiltersTheErrorNotTheAngle() {
        // Target just across the ±π seam: the filter must take the short way round.
        let current = (179.0).radians
        let target = -(179.0).radians
        let next = lowpassAngle(current: current, target: target, tau: 1, dt: 1)
        // Short way is +2°, so the result must be past +179° (i.e. wrapped negative), never near 0.
        XCTAssertGreaterThan(abs(next), (170.0).radians)
    }

    func testLowpassAngleConvergesMonotonically() {
        var v = 0.0
        for _ in 0..<200 { v = lowpassAngle(current: v, target: 1.0, tau: 1, dt: 0.1) }
        XCTAssertEqual(v, 1.0, accuracy: 1e-6)
    }

    func testLowpassAngleWithZeroDtHolds() {
        XCTAssertEqual(lowpassAngle(current: 0.5, target: 2.0, tau: 1, dt: 0), 0.5)
    }

    func testAtan2BearingContract() {
        XCTAssertEqual(atan2Bearing(east: 0, north: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(atan2Bearing(east: 1, north: 0), .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(atan2Bearing(east: -1, north: 0), -.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(atan2Bearing(east: 0, north: -1), -.pi, accuracy: 1e-12)
    }

    func testBearingToUnitENURoundTrip() {
        for deg in stride(from: -180.0, to: 180.0, by: 7) {
            let b = deg.radians
            let v = bearingToUnitENU(b)
            XCTAssertEqual(atan2Bearing(east: v.east, north: v.north), wrapToPi(b), accuracy: 1e-9)
        }
    }

    func testCompassLabels() {
        XCTAssertEqual(compassLabel(bearingRadians: 0), "N")
        XCTAssertEqual(compassLabel(bearingRadians: .pi / 2), "E")
        XCTAssertEqual(compassLabel(bearingRadians: -.pi / 2), "W")
        XCTAssertEqual(compassLabel(bearingRadians: .pi / 4), "NE")
    }
}
