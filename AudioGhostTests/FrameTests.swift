import XCTest
import simd
@testable import AudioGhost

/// The three canonical tests of spec §6.6 — they *define* correctness for the whole rotation
/// chain — plus the position mapping of §5.2. Synthetic attitudes are constructed from the same
/// `Frames` constants as the implementation, so the tests exercise the full composition.
final class FrameTests: XCTestCase {

    /// Two very different sensor frames, to prove nothing downstream depends on the defaults.
    static let configs: [(String, FrameConfig)] = [
        ("default (x forward, z up)", FrameConfig()),
        ("scenekit-like (−z forward, y up)", {
            var c = FrameConfig()
            c.headForwardLocal = SIMD3(0, 0, -1)
            c.headUpLocal = SIMD3(0, 1, 0)
            return c
        }()),
        ("mirrored reference vertical", {
            var c = FrameConfig()
            c.headForwardLocal = SIMD3(0, 1, 0)
            c.headUpLocal = SIMD3(0, 0, -1)
            c.referenceUpSign = -1
            return c
        }()),
        // The real thing: measured by FrameProbe on AirPods + iPhone 13 mini, 2026-07-28.
        // Roughly +x out the right ear, +y out the nose, +z out the top of the head, tilted
        // ~15–20° by how the buds actually sit. Kept here so the canonical tests cover the frame
        // the app is really running with, not only tidy hypotheses.
        ("measured (device, 2026-07-28)", {
            var c = FrameConfig()
            c.headForwardLocal = SIMD3(-0.2950805955118582, 0.9395541981060875, -0.17368175198792185)
            c.headUpLocal = SIMD3(-0.21914930038751534, 0.1103770632451075, 0.969427917923271)
            c.referenceUpSign = 1
            return c
        }())
    ]

    /// The measured frame must be a valid basis: unit vectors, exactly perpendicular (forward is
    /// derived as up × right, so this is a real invariant), and right-handed with a positive
    /// turn-right yaw sense.
    func testMeasuredFrameIsAWellFormedBasis() {
        let cfg = Self.configs.first { $0.0.hasPrefix("measured") }!.1
        XCTAssertEqual(simd_length(cfg.headForwardLocal), 1, accuracy: 1e-6)
        XCTAssertEqual(simd_length(cfg.headUpLocal), 1, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(cfg.headForwardLocal, cfg.headUpLocal), 0, accuracy: 1e-6,
                       "forward must be perpendicular to the gravity-derived up")
        // Turning right must increase the compass-convention yaw.
        let level = attitude(attitudeYaw: 0, pitch: 0, cfg: cfg)
        let turned = (level * Quat.rotation(angle: -(30.0).radians, axis: cfg.headUpLocal)).normalized
        let delta = wrapToPi(Frames.attitudeYaw(turned, cfg: cfg, fallback: 0)
                             - Frames.attitudeYaw(level, cfg: cfg, fallback: 0))
        XCTAssertEqual(delta, (30.0).radians, accuracy: 1e-6, "turning right must increase yaw")
    }

    /// Why the imperfect FrameProbe cross-checks (73° instead of 90°, roll axis 29° off) are
    /// tolerable: `forward` is built as `up × right` with `up` coming from gravity, so any error
    /// in the measured nod axis survives only as a rotation *about up* — a constant yaw offset,
    /// which the compass calibration absorbs exactly. This test injects a deliberate 25° error
    /// into the nod axis and shows the rendered world direction is unchanged once calibrated.
    func testNodAxisErrorIsAbsorbedByCalibration() {
        let truth = Self.configs.first { $0.0.hasPrefix("measured") }!.1

        // A frame measured with the ear-to-ear axis 25° off, rotated about the same up vector.
        var sloppy = truth
        let error = Quat.rotation(angle: (25.0).radians, axis: truth.headUpLocal)
        sloppy.headForwardLocal = error.act(truth.headForwardLocal)

        for trueYawDeg in stride(from: -150.0, through: 150.0, by: 30) {
            let trueYaw = trueYawDeg.radians
            // Same physical head pose, described in both frames.
            let q = attitude(attitudeYaw: Frames.attitudeYaw(
                attitude(attitudeYaw: trueYaw, pitch: 0, cfg: truth), cfg: truth, fallback: 0),
                             pitch: 0, cfg: truth)

            // Each frame calibrates against the same physical north.
            let offsetTruth = wrapToPi(trueYaw - Frames.attitudeYaw(q, cfg: truth, fallback: 0))
            let offsetSloppy = wrapToPi(trueYaw - Frames.attitudeYaw(q, cfg: sloppy, fallback: 0))

            let a = Frames.listenerRotation(attitude: q, yawOffset: offsetTruth, cfg: truth)
                .act(Frames.listenerLocalForward)
            let b = Frames.listenerRotation(attitude: q, yawOffset: offsetSloppy, cfg: sloppy)
                .act(Frames.listenerLocalForward)
            assertVector(b, a, "nose direction @ \(trueYawDeg)°", accuracy: 1e-6)
        }
    }

    // MARK: Helpers

    /// A synthetic attitude sample for a head whose nose has pseudo-yaw `attitudeYaw` (the
    /// arbitrary-origin compass convention of `Frames.attitudeYaw`) and the given pitch.
    private func attitude(attitudeYaw a: Double, pitch: Double, cfg: FrameConfig) -> simd_quatd {
        let s = cfg.referenceUpSign >= 0 ? 1.0 : -1.0
        // attitudeYaw = −ccw·s ⇒ ccw = −a·s
        let ccw = -a * s
        let forward = SIMD3<Double>(cos(ccw) * cos(pitch),
                                    sin(ccw) * cos(pitch),
                                    sin(pitch) * s)
        let up = SIMD3<Double>(-cos(ccw) * sin(pitch),
                               -sin(ccw) * sin(pitch),
                               cos(pitch) * s)
        return Quat.rotation(fromForward: cfg.headForwardLocal, fromUp: cfg.headUpLocal,
                             toForward: forward, toUp: up)
    }

    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              _ message: String, accuracy: Double = 1e-6,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(message) x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(message) y", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "\(message) z", file: file, line: line)
    }

    // MARK: Sanity of the synthetic generator itself

    func testSyntheticAttitudeReproducesItsOwnYaw() {
        for (name, cfg) in Self.configs {
            for yawDeg in stride(from: -170.0, through: 170.0, by: 17) {
                let q = attitude(attitudeYaw: yawDeg.radians, pitch: 0, cfg: cfg)
                XCTAssertEqual(Frames.attitudeYaw(q, cfg: cfg, fallback: 0), yawDeg.radians,
                               accuracy: 1e-9, "\(name) @ \(yawDeg)°")
            }
        }
    }

    func testAttitudePitchIsRecovered() {
        for (name, cfg) in Self.configs {
            for pitchDeg in [-60.0, -30.0, 0.0, 30.0, 60.0] {
                let q = attitude(attitudeYaw: 0.7, pitch: pitchDeg.radians, cfg: cfg)
                XCTAssertEqual(Frames.attitudePitch(q, cfg: cfg), pitchDeg.radians,
                               accuracy: 1e-9, "\(name) pitch \(pitchDeg)°")
            }
        }
    }

    func testGimbalGuardHoldsLastYawWhenNoseIsVertical() {
        let cfg = FrameConfig()
        let q = attitude(attitudeYaw: 0.3, pitch: (89.9).radians, cfg: cfg)
        XCTAssertEqual(Frames.attitudeYaw(q, cfg: cfg, fallback: 1.234), 1.234, accuracy: 1e-12)
    }

    // MARK: The three canonical tests (§6.6)

    /// 1. Level head, trueYaw = 0 ⇒ nose points north (0,0,−1) and up is (0,1,0) in PHASE world.
    func testCanonical1_LevelFacingNorth() {
        for (name, cfg) in Self.configs {
            // The raw attitude yaw is arbitrary; calibration absorbs it.
            let a = 1.1
            let q = attitude(attitudeYaw: a, pitch: 0, cfg: cfg)
            let yawOffset = wrapToPi(0 - a)
            let listener = Frames.listenerRotation(attitude: q, yawOffset: yawOffset, cfg: cfg)
            assertVector(listener.act(Frames.listenerLocalForward), SIMD3(0, 0, -1), "\(name) forward")
            assertVector(listener.act(Frames.listenerLocalUp), SIMD3(0, 1, 0), "\(name) up")
        }
    }

    /// 2. Level head, trueYaw = +90° (east) ⇒ nose points (1,0,0).
    func testCanonical2_LevelFacingEast() {
        for (name, cfg) in Self.configs {
            let a = -2.4
            let q = attitude(attitudeYaw: a, pitch: 0, cfg: cfg)
            let yawOffset = wrapToPi(.pi / 2 - a)
            let listener = Frames.listenerRotation(attitude: q, yawOffset: yawOffset, cfg: cfg)
            assertVector(listener.act(Frames.listenerLocalForward), SIMD3(1, 0, 0), "\(name) forward")
            assertVector(listener.act(Frames.listenerLocalUp), SIMD3(0, 1, 0), "\(name) up")
        }
    }

    /// 3. Facing north, pitched up 30° ⇒ nose points (0, sin30°, −cos30°).
    func testCanonical3_FacingNorthPitchedUp30() {
        for (name, cfg) in Self.configs {
            let a = 0.42
            let pitch = (30.0).radians
            let q = attitude(attitudeYaw: a, pitch: pitch, cfg: cfg)
            let yawOffset = wrapToPi(0 - a)
            let listener = Frames.listenerRotation(attitude: q, yawOffset: yawOffset, cfg: cfg)
            assertVector(listener.act(Frames.listenerLocalForward),
                         SIMD3(0, sin(pitch), -cos(pitch)), "\(name) forward")
        }
    }

    /// The whole point of the offset: turning the head must rotate the world the *other* way, so
    /// a world-fixed direction stays put.
    func testWorldStabilityUnderHeadTurns() {
        for (name, cfg) in Self.configs {
            let yawOffset = wrapToPi(0 - 0.9)
            // The listener faces different directions; a world-north vector expressed in
            // listener-local coordinates must rotate correspondingly.
            for turnDeg in stride(from: -170.0, through: 170.0, by: 23) {
                let trueYaw = turnDeg.radians
                let a = wrapToPi(trueYaw - yawOffset)
                let q = attitude(attitudeYaw: a, pitch: 0, cfg: cfg)
                let listener = Frames.listenerRotation(attitude: q, yawOffset: yawOffset, cfg: cfg)
                let noseInWorld = listener.act(Frames.listenerLocalForward)
                // Nose bearing in the PHASE world: x = east, −z = north.
                let bearing = atan2Bearing(east: noseInWorld.x, north: -noseInWorld.z)
                XCTAssertEqual(bearing, wrapToPi(trueYaw), accuracy: 1e-9, "\(name) @ \(turnDeg)°")
            }
        }
    }

    func testConjugateFlipInvertsTheRotation() {
        var cfg = FrameConfig()
        let q = attitude(attitudeYaw: 0.3, pitch: 0, cfg: cfg)
        let normal = Frames.listenerRotation(attitude: q, yawOffset: 0.2, cfg: cfg)
        cfg.conjugateListener = true
        let flipped = Frames.listenerRotation(attitude: q, yawOffset: 0.2, cfg: cfg)
        assertVector(flipped.act(normal.act(SIMD3(0, 0, -1))), SIMD3(0, 0, -1), "conjugate round trip")
    }

    func testYawOffsetSignFlipMirrorsTheAppliedOffset() {
        var cfg = FrameConfig()
        let q = attitude(attitudeYaw: 0, pitch: 0, cfg: cfg)
        let plus = Frames.listenerRotation(attitude: q, yawOffset: 0.5, cfg: cfg)
        cfg.flipYawOffsetSign = true
        let minus = Frames.listenerRotation(attitude: q, yawOffset: 0.5, cfg: cfg)
        let a = plus.act(Frames.listenerLocalForward)
        let b = minus.act(Frames.listenerLocalForward)
        XCTAssertEqual(atan2Bearing(east: a.x, north: -a.z),
                       -atan2Bearing(east: b.x, north: -b.z), accuracy: 1e-9)
    }

    // MARK: Position mapping (§5.2)

    func testPhasePositionMapping() {
        let cfg = FrameConfig()
        let enu = SIMD3<Double>(3, 5, 7)               // 3 m east, 5 m north, 7 m up
        let p = Frames.phasePosition(enu, cfg: cfg)
        XCTAssertEqual(p.x, 3, accuracy: 1e-6)         // east  → +x
        XCTAssertEqual(p.y, 7, accuracy: 1e-6)         // up    → +y
        XCTAssertEqual(p.z, -5, accuracy: 1e-6)        // north → −z
    }

    func testPhasePositionSignFlips() {
        var cfg = FrameConfig()
        cfg.flipEast = true
        XCTAssertEqual(Frames.phasePosition(SIMD3(3, 5, 7), cfg: cfg).x, -3, accuracy: 1e-6)
        cfg.flipEast = false
        cfg.flipNorth = true
        XCTAssertEqual(Frames.phasePosition(SIMD3(3, 5, 7), cfg: cfg).z, 5, accuracy: 1e-6)
    }

    func testENUToPhaseIsAProperRotation() {
        let c = Frames.enuToPhase
        assertVector(c.act(SIMD3(1, 0, 0)), SIMD3(1, 0, 0), "east")
        assertVector(c.act(SIMD3(0, 1, 0)), SIMD3(0, 0, -1), "north")
        assertVector(c.act(SIMD3(0, 0, 1)), SIMD3(0, 1, 0), "up")
    }

    // MARK: Quaternion helpers

    func testBasisRoundTrip() {
        let q = Quat.rotation(fromForward: SIMD3(0, 0, -1), fromUp: SIMD3(0, 1, 0),
                              toForward: SIMD3(1, 0, 0), toUp: SIMD3(0, 1, 0))
        assertVector(q.act(SIMD3(0, 0, -1)), SIMD3(1, 0, 0), "forward")
        assertVector(q.act(SIMD3(0, 1, 0)), SIMD3(0, 1, 0), "up")
    }

    func testBasisHandednessConvention() {
        // R = F × U, checked against the SceneKit basis the project standardises on.
        let f = SIMD3<Double>(0, 0, -1), u = SIMD3<Double>(0, 1, 0)
        assertVector(simd_cross(f, u), SIMD3(1, 0, 0), "right")
    }

    func testAxisOfRotation() {
        let q = Quat.rotation(angle: 0.7, axis: SIMD3(0, 0, 1))
        assertVector(Quat.axis(of: q)!, SIMD3(0, 0, 1), "axis", accuracy: 1e-9)
        XCTAssertNil(Quat.axis(of: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)))
    }

    func testTransformIsRigid() {
        let q = Quat.rotation(angle: 0.4, axis: SIMD3(0, 1, 0))
        let m = Quat.transform(rotation: Quat.float(q), position: SIMD3(1, 2, 3))
        XCTAssertEqual(simd_length(m.columns.0), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(m.columns.1), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(m.columns.2), 1, accuracy: 1e-5)
        XCTAssertEqual(m.columns.3.x, 1, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.y, 2, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.z, 3, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.w, 1, accuracy: 1e-6)
    }

    // MARK: FrameProbe solver

    /// The probe must recover a known frame from synthetic "level" and "nod down" captures.
    func testFrameProbeSolverRecoversAKnownFrame() {
        // Ground truth: a SceneKit-like sensor frame.
        let truth = (forward: SIMD3<Double>(0, 0, -1), up: SIMD3<Double>(0, 1, 0))
        let right = simd_cross(truth.forward, truth.up)

        // Level head facing an arbitrary reference direction.
        let level = Quat.rotation(fromForward: truth.forward, fromUp: truth.up,
                                  toForward: SIMD3(cos(0.8), sin(0.8), 0), toUp: SIMD3(0, 0, 1))
        // Nodding 45° down = negative rotation about the right (ear-to-ear) axis.
        let nodLocal = Quat.rotation(angle: -(45.0).radians, axis: right)
        let nod = (level * nodLocal).normalized

        let gravityLevel = level.inverse.act(SIMD3<Double>(0, 0, -1))   // down, in sensor frame

        let solved = Frames.solveSensorFrame(levelAttitude: level, levelGravity: gravityLevel,
                                             nodDownAttitude: nod)
        assertVector(solved!.up, truth.up, "solved up", accuracy: 1e-9)
        assertVector(solved!.right, right, "solved right", accuracy: 1e-9)
        assertVector(solved!.forward, truth.forward, "solved forward", accuracy: 1e-9)
        XCTAssertEqual(solved!.referenceUpSign, 1)
    }

    func testFrameProbeSolverRefusesANodThatDidNotMove() {
        let level = Quat.rotation(angle: 0.3, axis: SIMD3(0, 0, 1))
        XCTAssertNil(Frames.solveSensorFrame(levelAttitude: level, levelGravity: SIMD3(0, 0, -1),
                                             nodDownAttitude: level))
    }

    // MARK: Persistence

    /// The frame measured on the device lives in `UserDefaults` as JSON written by an older build,
    /// which also carried a `mountingCorrection` field. It must keep decoding: a failure here
    /// silently throws away the measured frame and falls back to the 90°-wrong defaults.
    func testPreviouslySavedFrameConfigStillDecodes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
        let saved = """
        {"headForwardLocal":[-0.295,0.94,-0.174],"headUpLocal":[-0.219,0.11,0.969],\
        "referenceUpSign":1,"mountingCorrection":[0,0,0,1],"flipEast":false,"flipNorth":false,\
        "conjugateListener":true,"flipYawOffsetSign":false,"probedAt":806932800,"probeNotes":"field"}
        """
        defaults.set(Data(saved.utf8), forKey: "FrameConfig.v1")

        let config = FrameConfigStore(defaults: defaults).config
        XCTAssertEqual(config.headForwardLocal, SIMD3(-0.295, 0.94, -0.174))
        XCTAssertEqual(config.headUpLocal, SIMD3(-0.219, 0.11, 0.969))
        XCTAssertTrue(config.conjugateListener)
        XCTAssertEqual(config.probeNotes, "field")
        XCTAssertNotNil(config.probedAt)
    }

    func testFrameConfigRoundTripsThroughTheStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
        let store = FrameConfigStore(defaults: defaults)
        store.observed.flipEast = true
        XCTAssertTrue(store.config.flipEast, "the tracking-queue copy must follow the UI")
        XCTAssertTrue(FrameConfigStore(defaults: defaults).config.flipEast, "and it must persist")
    }

    func testMeanQuaternionIgnoresHemisphereFlips() {
        let a = Quat.rotation(angle: 0.5, axis: SIMD3(0, 0, 1))
        let negated = simd_quatd(vector: -a.vector)
        let mean = FrameProbeModel.meanQuaternion([a, negated, a])
        XCTAssertEqual(abs(simd_dot(mean.vector, a.vector)), 1, accuracy: 1e-9)
    }
}
