import XCTest
import simd
@testable import AudioGhost

/// Appendix B worked vectors. If a case fails by a near-constant scale factor, the bug is
/// degrees-vs-radians at a trig boundary — the classic failure the spec warns about.
final class GeoTests: XCTestCase {

    let origin = Geo.Coordinate(latitude: 43.949317, longitude: 4.805528)   // Avignon

    func test100mNorth() {
        let p = Geo.Coordinate(latitude: 43.950216, longitude: 4.805528)
        let enu = Geo.enu(of: p, origin: origin)
        XCTAssertEqual(enu.x, 0, accuracy: 0.15)
        XCTAssertEqual(enu.y, 100, accuracy: 0.15)
        XCTAssertEqual(enu.z, 0)
    }

    func test100mEast() {
        let p = Geo.Coordinate(latitude: 43.949317, longitude: 4.806777)
        let enu = Geo.enu(of: p, origin: origin)
        XCTAssertEqual(enu.x, 100, accuracy: 0.15)
        XCTAssertEqual(enu.y, 0, accuracy: 0.15)
    }

    func testDiagonalNorthEast() {
        let p = Geo.Coordinate(latitude: 43.950216, longitude: 4.806777)
        let enu = Geo.enu(of: p, origin: origin)
        XCTAssertEqual(enu.x, 100, accuracy: 0.3)
        XCTAssertEqual(enu.y, 100, accuracy: 0.3)
        XCTAssertEqual(Geo.horizontalLength(enu), 141.4, accuracy: 0.5)
    }

    func test1kmSouth() {
        let p = Geo.Coordinate(latitude: 43.940324, longitude: 4.805528)
        let enu = Geo.enu(of: p, origin: origin)
        XCTAssertEqual(enu.x, 0, accuracy: 1.5)
        XCTAssertEqual(enu.y, -1000, accuracy: 1.5)
    }

    func testBearings() {
        let north = Geo.Coordinate(latitude: 43.950216, longitude: 4.805528)
        let east = Geo.Coordinate(latitude: 43.949317, longitude: 4.806777)
        XCTAssertEqual(Geo.bearing(from: origin, to: north), 0, accuracy: 1e-6)
        XCTAssertEqual(Geo.bearing(from: origin, to: east), .pi / 2, accuracy: 1e-4)
    }

    func testRoundTripStableToAMillimetreAt500m() {
        for (e, n) in [(500.0, 0.0), (0.0, 500.0), (-354.0, 354.0), (300.0, -400.0)] {
            let enu = SIMD3<Double>(e, n, 0)
            let coordinate = Geo.coordinate(fromENU: enu, origin: origin)
            let back = Geo.enu(of: coordinate, origin: origin)
            XCTAssertEqual(back.x, e, accuracy: 0.001, "east round trip")
            XCTAssertEqual(back.y, n, accuracy: 0.001, "north round trip")
        }
    }

    func testDistanceMatchesHorizontalLengthOfENU() {
        let p = Geo.Coordinate(latitude: 43.9530, longitude: 4.8100)
        let d = Geo.distance(from: origin, to: p)
        let enu = Geo.enu(of: p, origin: origin)
        XCTAssertEqual(Geo.horizontalLength(enu), d, accuracy: 1e-6)
    }

    func testAntimeridianDoesNotExplode() {
        // Sessions never span it, but a wrapped Δλ must not produce a half-planet distance.
        let a = Geo.Coordinate(latitude: 0, longitude: 179.9995)
        let b = Geo.Coordinate(latitude: 0, longitude: -179.9995)
        let d = Geo.distance(from: a, to: b)
        XCTAssertLessThan(d, 200)
        XCTAssertEqual(Geo.bearing(from: a, to: b), .pi / 2, accuracy: 1e-3)
    }

    func testZeroDistanceIsStable() {
        let enu = Geo.enu(of: origin, origin: origin)
        XCTAssertEqual(Geo.horizontalLength(enu), 0, accuracy: 1e-9)
        let back = Geo.coordinate(fromENU: .zero, origin: origin)
        XCTAssertEqual(back.latitude, origin.latitude, accuracy: 1e-12)
        XCTAssertEqual(back.longitude, origin.longitude, accuracy: 1e-12)
    }

    func testCoordinatePairParsing() {
        XCTAssertEqual(Geo.parseCoordinatePair("48.8584, 2.2945")?.latitude, 48.8584)
        XCTAssertEqual(Geo.parseCoordinatePair("48.8584, 2.2945")?.longitude, 2.2945)
        XCTAssertEqual(Geo.parseCoordinatePair("  -33.8688 151.2093 ")?.latitude, -33.8688)
        XCTAssertNil(Geo.parseCoordinatePair("48.8584"))
        XCTAssertNil(Geo.parseCoordinatePair("nonsense"))
        XCTAssertNil(Geo.parseCoordinatePair("100.0, 5.0"))   // latitude out of range
    }
}
