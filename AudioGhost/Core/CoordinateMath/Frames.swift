import Foundation
import simd

// =====================================================================================
// FRAME CONVENTIONS — the single place these are written down (spec §5.2, §6.1, §6.6).
// Keep this table in sync with CLAUDE.md.
//
//  1. SENSOR / HEAD-LOCAL frame  (CMDeviceMotion from CMHeadphoneMotionManager)
//     Axes are NOT documented by Apple and community reports conflict, so they are treated
//     as MEASURED DATA, not constants: `FrameConfig.headForwardLocal` / `.headUpLocal` are
//     produced by the in-app FrameProbe (§6.1) and persisted. Everything downstream is written
//     against those two vectors, never against literal axes.
//     The defaults below are only a starting hypothesis, and the real device measured them
//     wrong by 90° (see CLAUDE.md §2). A fresh install must run FrameProbe.
//
//  2. COREMOTION REFERENCE frame — gravity-aligned, vertical along ±z (sign measured into
//     `FrameConfig.referenceUpSign`), horizontal axes ARBITRARY and re-randomised on every
//     AirPods reconnect. Only *changes* in yaw are meaningful; `CalibrationService.yawOffset`
//     absorbs the constant.
//
//  3. ENU — local tangent plane, meters, stored as SIMD3(x: east, y: north, z: up).
//
//  4. PHASE WORLD — right-handed, y-up: +x east, +y up, −z north. So the identity listener
//     faces true north. Position remap in `Frames.phasePosition`.
//
//  5. PHASE LISTENER-LOCAL — SceneKit convention: −z out of the nose, +y out of the top of
//     the head, +x out of the right ear.
// =====================================================================================

/// Measured description of the headphone sensor frame plus the §15 field sign flips.
///
/// Persisted as JSON by `FrameConfigStore`. Synthesized decoding requires every non-optional key
/// to be present, so a new non-optional field makes the config saved on the device undecodable —
/// and the measured frame is silently replaced by the defaults. New fields must be optional.
struct FrameConfig: Codable, Equatable {

    /// Sensor-frame vector pointing out of the nose. UNVERIFIED default; run FrameProbe.
    var headForwardLocal: SIMD3<Double> = SIMD3(1, 0, 0)

    /// Sensor-frame vector pointing out of the top of the head. UNVERIFIED default; run FrameProbe.
    var headUpLocal: SIMD3<Double> = SIMD3(0, 0, 1)

    /// +1 if the CoreMotion reference frame's +z points up, −1 if it points down.
    /// FrameProbe measures this (a level head must map `headUpLocal` onto reference +z).
    var referenceUpSign: Double = 1

    /// Field-walk sign flips (§15). All default to "spec's intended design"; the troubleshooting
    /// tree turns a wrong convention into a toggle in the Debug HUD instead of a rebuild.
    var flipEast: Bool = false           // §15.1 left/right mirrored
    var flipNorth: Bool = false          // §15.2 front/back mirrored
    var conjugateListener: Bool = false  // §15.4 head turns move the source the same way
    var flipYawOffsetSign: Bool = false  // §15.5 constant offset calibration can't fix

    var probedAt: Date?
    var probeNotes: String = ""
}

enum Frames {

    // MARK: Fixed frame changes

    /// PHASE listener-local nose direction and up direction.
    static let listenerLocalForward = SIMD3<Double>(0, 0, -1)
    static let listenerLocalUp = SIMD3<Double>(0, 1, 0)

    /// `C` (spec §6.6): ENU components → PHASE-world components. (e, n, u) ↦ (e, u, −n).
    static let enuToPhase: simd_quatd = Quat.rotation(
        fromForward: SIMD3(0, 1, 0), fromUp: SIMD3(0, 0, 1),      // ENU: north, up
        toForward: SIMD3(0, 0, -1), toUp: SIMD3(0, 1, 0))         // PHASE: north, up

    /// `H` (spec §6.6): PHASE-listener-local → sensor-head-local, from the measured vectors.
    static func listenerLocalToSensor(_ cfg: FrameConfig) -> simd_quatd {
        Quat.rotation(fromForward: listenerLocalForward, fromUp: listenerLocalUp,
                      toForward: cfg.headForwardLocal, toUp: cfg.headUpLocal)
    }

    /// `referenceUpSign` reduced to exactly ±1.
    private static func referenceSign(_ cfg: FrameConfig) -> Double {
        cfg.referenceUpSign >= 0 ? 1 : -1
    }

    /// Reference-frame vertical as a vector (±z per the measured `referenceUpSign`).
    static func referenceUp(_ cfg: FrameConfig) -> SIMD3<Double> {
        SIMD3(0, 0, referenceSign(cfg))
    }

    // MARK: Yaw

    /// Yaw of the nose derived from a raw attitude sample, in the *pseudo-compass* convention:
    /// radians clockwise from the reference frame's arbitrary "x" direction, in [−π, π).
    ///
    /// Its absolute value is meaningless (the reference frame's horizontal axes are arbitrary and
    /// reset on reconnect); only differences matter, and `CalibrationService.yawOffset` absorbs
    /// the constant: `trueYaw = wrapToPi(attitudeYaw + yawOffset)`.
    ///
    /// Returns `fallback` when the nose is within ~3° of vertical (gimbal guard: someone lying on
    /// the grass looking straight up must hold their last yaw rather than emit noise).
    static func attitudeYaw(_ q: simd_quatd, cfg: FrameConfig, fallback: Double) -> Double {
        let f = q.act(simd_normalize(cfg.headForwardLocal))
        // Horizontal projection in the reference frame; reference vertical is ±z.
        let fh = SIMD2<Double>(f.x, f.y)
        guard simd_length(fh) > 0.05 else { return fallback }
        let ccw = atan2(fh.y, fh.x)
        // Compass-style: clockwise positive. `referenceUpSign` flips the sense of "clockwise"
        // when the reference vertical points down.
        return wrapToPi(-ccw * referenceSign(cfg))
    }

    /// Pitch of the nose above the horizon, radians (positive = looking up). Diagnostics only.
    static func attitudePitch(_ q: simd_quatd, cfg: FrameConfig) -> Double {
        let f = simd_normalize(q.act(simd_normalize(cfg.headForwardLocal)))
        return asin(clamp(f.z * referenceSign(cfg), -1, 1))
    }

    // MARK: Composition

    /// `R` (spec §6.6): CoreMotion-reference components → ENU components, realizing
    /// `trueYaw = attitudeYaw + yawOffset`.
    ///
    /// Construction: the reference-frame vector (1,0,0) has `attitudeYaw == 0` by definition, so
    /// it must land on the ENU horizontal direction whose bearing is exactly `yawOffset`; the
    /// reference vertical must land on ENU up. Two direction pairs fix the rotation.
    static func referenceToENU(yawOffset: Double, cfg: FrameConfig) -> simd_quatd {
        let yo = cfg.flipYawOffsetSign ? -yawOffset : yawOffset
        let dir = bearingToUnitENU(yo)
        return Quat.rotation(fromForward: SIMD3(1, 0, 0), fromUp: referenceUp(cfg),
                             toForward: SIMD3(dir.east, dir.north, 0), toUp: SIMD3(0, 0, 1))
    }

    /// The full listener rotation for PHASE: `q_PHASE = C ∘ R ∘ q_attitude ∘ H` (spec §6.6).
    ///
    /// `attitude` is the raw sample *after* mounting correction (applied in HeadTrackingService).
    static func listenerRotation(attitude: simd_quatd, yawOffset: Double, cfg: FrameConfig) -> simd_quatd {
        let q = (enuToPhase
                 * referenceToENU(yawOffset: yawOffset, cfg: cfg)
                 * attitude.normalized
                 * listenerLocalToSensor(cfg)).normalized
        return cfg.conjugateListener ? q.inverse : q
    }

    // MARK: Positions

    /// ENU (x: east, y: north, z: up) → PHASE world (x: east, y: up, z: −north).
    /// The component shuffle is written out explicitly on purpose — no clever swizzles.
    @inline(__always)
    static func phasePosition(_ enu: SIMD3<Double>, cfg: FrameConfig) -> SIMD3<Float> {
        let east = cfg.flipEast ? -enu.x : enu.x
        let north = cfg.flipNorth ? -enu.y : enu.y
        let up = enu.z
        return SIMD3<Float>(Float(east), Float(up), Float(-north))
    }

    // MARK: FrameProbe solver (spec §6.1)

    struct SolvedSensorFrame: Equatable {
        var forward: SIMD3<Double>
        var up: SIMD3<Double>
        var right: SIMD3<Double>
        var referenceUpSign: Double
    }

    /// Solves for the sensor frame from a "head level" capture and a "nod down" capture:
    ///   * up      = −(gravity at level) — gravity is unambiguous.
    ///   * right   = −(rotation axis of the nod), because a downward nod is a NEGATIVE rotation
    ///               about the ear-to-ear axis (right-hand rule with forward × up = right).
    ///   * forward = up × right, so any error in the nod axis survives only as a rotation about
    ///               `up` — a constant yaw offset, which calibration absorbs exactly.
    ///
    /// Returns nil if the nod didn't move enough to define an axis.
    static func solveSensorFrame(levelAttitude: simd_quatd,
                                 levelGravity: SIMD3<Double>,
                                 nodDownAttitude: simd_quatd) -> SolvedSensorFrame? {
        let up = simd_normalize(-levelGravity)
        guard let nodAxis = Quat.axis(of: (levelAttitude.inverse * nodDownAttitude).normalized) else {
            return nil
        }
        let measuredRight = -nodAxis
        let right = simd_normalize(measuredRight - up * simd_dot(measuredRight, up))
        let forward = simd_normalize(simd_cross(up, right))
        // With a level head, the top of the head must map onto the reference frame's vertical.
        let referenceUpSign: Double = levelAttitude.act(up).z >= 0 ? 1 : -1
        return SolvedSensorFrame(forward: forward, up: up, right: right, referenceUpSign: referenceUpSign)
    }
}
