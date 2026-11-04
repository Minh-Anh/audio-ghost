import Foundation
import simd

/// Quaternion / basis helpers. Everything here is pure and unit-tested.
///
/// Handedness convention used throughout the project, stated once so it is never re-derived:
/// for a right-handed frame with `forward` (F), `up` (U) and `right` (R),
///
///     R = F × U            (check: F = (0,0,-1), U = (0,1,0)  ⇒  R = (1,0,0), i.e. SceneKit's basis)
///     U = R × F
///
enum Quat {

    /// Orthonormal right-handed basis matrix whose columns are (right, up, back = −forward).
    /// `forward` and `up` need not be exactly orthogonal or normalized; they are Gram-Schmidt'd.
    static func basis(forward: SIMD3<Double>, up: SIMD3<Double>) -> simd_double3x3 {
        let u = simd_normalize(up)
        var f = forward - u * simd_dot(forward, u)
        if simd_length(f) < 1e-9 {
            // Degenerate input (forward parallel to up): pick any perpendicular direction so we
            // still return a valid rotation rather than NaNs.
            let seed = abs(u.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            f = seed - u * simd_dot(seed, u)
        }
        f = simd_normalize(f)
        let r = simd_cross(f, u)
        return simd_double3x3(columns: (r, u, -f))
    }

    /// The rotation that carries the frame described by (`fromForward`, `fromUp`) onto the frame
    /// described by (`toForward`, `toUp`). Built from explicit basis vectors — never from
    /// hand-typed quaternion components (spec §6.6).
    static func rotation(fromForward: SIMD3<Double>, fromUp: SIMD3<Double>,
                         toForward: SIMD3<Double>, toUp: SIMD3<Double>) -> simd_quatd {
        let a = basis(forward: fromForward, up: fromUp)
        let b = basis(forward: toForward, up: toUp)
        return simd_quatd(simd_mul(b, a.transpose)).normalized
    }

    /// Rotation of `angle` radians about `axis`, right-hand rule.
    static func rotation(angle: Double, axis: SIMD3<Double>) -> simd_quatd {
        simd_quatd(angle: angle, axis: simd_normalize(axis))
    }

    static func float(_ q: simd_quatd) -> simd_quatf {
        let n = q.normalized
        return simd_quatf(ix: Float(n.imag.x), iy: Float(n.imag.y), iz: Float(n.imag.z), r: Float(n.real))
    }

    /// Rigid transform (rotation + translation, no scale ever — PHASE requires rigid listener
    /// and source transforms, spec §5.2).
    static func transform(rotation: simd_quatf, position: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(rotation.normalized)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    /// Rotation axis of a quaternion, or nil if the rotation is (numerically) identity.
    static func axis(of q: simd_quatd) -> SIMD3<Double>? {
        let n = q.normalized
        let s = simd_length(n.imag)
        guard s > 1e-6 else { return nil }
        // Sign convention: return the axis for the positive-angle interpretation.
        let a = n.imag / s
        return n.real < 0 ? -a : a
    }
}

// `normalized` comes from the simd module itself; do not redeclare it here — an overlapping
// extension makes every call site ambiguous.

extension simd_quatd {
    /// Identity rotation, spelled once.
    static let identityRotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
}

extension simd_quatf {
    static let identityRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
}
