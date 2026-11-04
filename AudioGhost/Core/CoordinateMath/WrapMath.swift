import Foundation

// MARK: - Angle conventions
//
// All angles in this project are RADIANS. Degrees exist only at UI and CoreLocation
// boundaries. Two angle conventions coexist and must never be confused:
//
//   * "bearing"  — radians CLOCKWISE from north, in [-π, π).  north = 0, east = +π/2.
//   * "ccw"      — mathematical angle counter-clockwise from +x, as returned by atan2(y, x).
//
// Conversions between them always go through `atan2Bearing` / `bearingToUnitENU`.

/// Wrap to [-π, π). `wrapToPi(π) == -π`, `wrapToPi(3π/2) == -π/2`.
@inline(__always)
func wrapToPi(_ x: Double) -> Double {
    var r = x.truncatingRemainder(dividingBy: 2 * .pi)
    if r >= .pi { r -= 2 * .pi }
    if r < -.pi { r += 2 * .pi }
    return r
}

/// Circular mean of angles (radians). `circularMean([359°, 1°]) == 0°`.
/// Returns nil when the resultant vector length is < 0.1 (angles spread around the circle,
/// so a mean is meaningless) or the input is empty.
func circularMean(_ angles: [Double]) -> Double? {
    guard !angles.isEmpty else { return nil }
    var sx = 0.0, sy = 0.0
    for a in angles {
        sx += cos(a)
        sy += sin(a)
    }
    sx /= Double(angles.count)
    sy /= Double(angles.count)
    let r = (sx * sx + sy * sy).squareRoot()
    guard r >= 0.1 else { return nil }
    return wrapToPi(atan2(sy, sx))
}

/// Resultant-vector length of a set of angles: 1 = perfectly concentrated, 0 = uniformly spread.
func circularConcentration(_ angles: [Double]) -> Double {
    guard !angles.isEmpty else { return 0 }
    var sx = 0.0, sy = 0.0
    for a in angles {
        sx += cos(a)
        sy += sin(a)
    }
    sx /= Double(angles.count)
    sy /= Double(angles.count)
    return (sx * sx + sy * sy).squareRoot()
}

/// Max angular spread (radians) of a set of angles around their circular mean.
/// Used by the calibration ritual to reject samples taken while the user moved.
func circularSpread(_ angles: [Double]) -> Double {
    guard let mean = circularMean(angles) else { return .pi }
    return angles.reduce(0) { max($0, abs(wrapToPi($1 - mean))) }
}

/// Wrap-aware exponential low-pass: filters the *error* through `wrapToPi` so that a target
/// crossing ±π does not sweep the filter the long way around the circle.
@inline(__always)
func lowpassAngle(current: Double, target: Double, tau: Double, dt: Double) -> Double {
    guard dt > 0 else { return current }
    guard tau > 0 else { return wrapToPi(target) }
    let alpha = 1 - exp(-dt / tau)
    return wrapToPi(current + alpha * wrapToPi(target - current))
}

/// Bearing (radians cw from north) of a horizontal ENU offset.
/// `atan2Bearing(east: 0, north: 1) == 0`; `atan2Bearing(east: 1, north: 0) == π/2`.
@inline(__always)
func atan2Bearing(east: Double, north: Double) -> Double {
    wrapToPi(atan2(east, north))
}

/// Unit ENU horizontal vector (east, north) for a bearing in radians cw from north.
@inline(__always)
func bearingToUnitENU(_ bearing: Double) -> (east: Double, north: Double) {
    (east: sin(bearing), north: cos(bearing))
}

@inline(__always)
func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
    min(max(x, lo), hi)
}

extension Double {
    /// Degrees → radians. Only used at UI / CoreLocation boundaries.
    @inline(__always) var radians: Double { self * .pi / 180 }
    /// Radians → degrees. Only used at UI / CoreLocation boundaries.
    @inline(__always) var degrees: Double { self * 180 / .pi }
}

/// Compass label for a bearing, e.g. "NE". UI only.
func compassLabel(bearingRadians: Double) -> String {
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    var deg = wrapToPi(bearingRadians).degrees
    if deg < 0 { deg += 360 }
    let idx = Int((deg / 45).rounded()) % 8
    return names[idx]
}
