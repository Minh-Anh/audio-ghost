import XCTest
@testable import AudioGhost

/// Field overrides must survive a launch, and "reset" must really restore the §12 table.
final class TuningTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
        Tuning.current = Tuning()
    }

    override func tearDown() {
        Tuning.current = Tuning()
        super.tearDown()
    }

    func testOverridesPersistAcrossLaunches() {
        Tuning.current.courseGain = 0.11
        Tuning.saveOverrides(to: defaults)
        Tuning.current = Tuning()                   // a new launch
        Tuning.loadOverrides(from: defaults)
        XCTAssertEqual(Tuning.current.courseGain, 0.11)
    }

    /// Overrides already saved on the device use this exact key and these exact names.
    func testPreviouslySavedOverridesStillLoad() {
        defaults.set(["tauMin": 2.5, "nearFieldFloor": 6.0], forKey: "Tuning.overrides.v1")
        Tuning.loadOverrides(from: defaults)
        XCTAssertEqual(Tuning.current.tauMin, 2.5)
        XCTAssertEqual(Tuning.current.nearFieldFloor, 6.0)
        XCTAssertEqual(Tuning.current.tauMax, 3.0, "knobs not in the table keep their defaults")
    }

    func testResetRestoresDefaultsAndForgetsTheOverrides() {
        Tuning.current.tauMin = 2.5
        Tuning.saveOverrides(to: defaults)
        Tuning.resetOverrides(in: defaults)
        XCTAssertEqual(Tuning.current.tauMin, 1.0)
        Tuning.current.tauMin = 2.5
        Tuning.loadOverrides(from: defaults)
        XCTAssertEqual(Tuning.current.tauMin, 2.5, "nothing left on disk to load")
    }

    func testDefaultsMatchTheSpecTable() {
        let t = Tuning()
        XCTAssertEqual(t.listenerEarHeight, 1.6)
        XCTAssertEqual(t.tauMin, 1)
        XCTAssertEqual(t.tauMax, 3)
        XCTAssertEqual(t.maxAcceptableAccuracy, 30)
        XCTAssertEqual(t.teleportDistance, 20)
        XCTAssertEqual(t.teleportCount, 3)
        XCTAssertEqual(t.deadReckonMax, 1.5)
        XCTAssertEqual(t.gpsStaleTimeout, 8)
        XCTAssertEqual(t.nearFieldFloor, 4)
        XCTAssertEqual(t.nearFieldBearingTau, 3)
        XCTAssertEqual(t.clampExitFactor, 1.25)
        XCTAssertEqual(t.courseMinSpeed, 0.8)
        XCTAssertEqual(t.courseGateAngle, (60.0).radians)
        XCTAssertEqual(t.courseGain, 0.02)
        XCTAssertEqual(t.motionStaleTimeout, 0.5)
    }
}
