import Foundation
import simd

/// Geodetic ↔ local-tangent-plane conversions (spec §5.1).
///
/// Pure functions, no CoreLocation dependency, so they are unit-testable on any platform.
/// ENU is stored as `SIMD3<Double>(x: east, y: north, z: up)` — meters. Never reorder these
/// components implicitly; the PHASE remap in `Frames.phasePosition` spells the shuffle out.
enum Geo {

    /// Mean Earth radius used by the spec's worked test vectors (Appendix B).
    static let earthRadius: Double = 6_371_000

    struct Coordinate: Equatable {
        var latitude: Double   // WGS84 degrees
        var longitude: Double  // WGS84 degrees
    }

    /// Great-circle distance in meters between two geodetic coordinates (haversine).
    static func distance(from a: Coordinate, to b: Coordinate) -> Double {
        let phi1 = a.latitude.radians
        let phi2 = b.latitude.radians
        let dPhi = phi2 - phi1
        // Wrap the longitude difference so that a pair straddling the antimeridian does not
        // produce a ~40 000 km "distance". Sessions never span it, but the math shouldn't explode.
        let dLambda = wrapToPi(b.longitude.radians - a.longitude.radians)
        let s = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        let c = 2 * atan2(s.squareRoot(), max(0, 1 - s).squareRoot())
        return earthRadius * c
    }

    /// Initial bearing in radians CLOCKWISE FROM TRUE NORTH, wrapped to [-π, π).
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let phi1 = a.latitude.radians
        let phi2 = b.latitude.radians
        let dLambda = wrapToPi(b.longitude.radians - a.longitude.radians)
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        return wrapToPi(atan2(y, x))
    }

    /// Geodetic → local ENU (meters) relative to `origin`. `up` is always 0 here;
    /// height is handled separately (spec §5.4) because GPS altitude is unusable.
    static func enu(of point: Coordinate, origin: Coordinate) -> SIMD3<Double> {
        let d = distance(from: origin, to: point)
        let theta = bearing(from: origin, to: point)
        return SIMD3<Double>(d * sin(theta), d * cos(theta), 0)
    }

    /// Inverse of `enu(of:origin:)` — the geodetic coordinate at a local ENU offset.
    /// Used by the map pin (drag → lat/lon) and by the round-trip unit test.
    static func coordinate(fromENU enu: SIMD3<Double>, origin: Coordinate) -> Coordinate {
        let d = (enu.x * enu.x + enu.y * enu.y).squareRoot()
        guard d > 0 else { return origin }
        let theta = atan2(enu.x, enu.y)                 // bearing cw from north
        let delta = d / earthRadius
        let phi1 = origin.latitude.radians
        let lambda1 = origin.longitude.radians
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1),
                                      cos(delta) - sin(phi1) * sin(phi2))
        return Coordinate(latitude: phi2.degrees, longitude: wrapToPi(lambda2).degrees)
    }

    /// Horizontal length of an ENU offset.
    @inline(__always)
    static func horizontalLength(_ v: SIMD3<Double>) -> Double {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    /// Parses "48.8584, 2.2945" (or "48.8584 2.2945", or a Maps-style paste with extra text)
    /// into a coordinate. Returns nil unless exactly two plausible numbers are found.
    static func parseCoordinatePair(_ text: String) -> Coordinate? {
        let scanner = text.replacingOccurrences(of: ",", with: " ")
        let numbers = scanner.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "()°NSEWnsew"))) }
        guard numbers.count == 2 else { return nil }
        let (lat, lon) = (numbers[0], numbers[1])
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}
