import XCTest
@testable import AudioGhost

/// §8.1 GPS complaints: when the heartbeat sends `.gpsWentStale` / `.gpsAccuracyPoor` /
/// `.gpsRecovered`. Clock-free — every test drives `GPSHealthMonitor` with explicit times and
/// feeds its events through the real reducer.
final class GPSHealthMonitorTests: XCTestCase {

    /// Spec defaults: stale after 8 s, weak above 15 m, accuracyPoor after 15 s of weak fixes.
    private let tuning = Tuning()
    private let heartbeat = 0.04     // 25 Hz

    private var monitor = GPSHealthMonitor()
    private var state: SessionState = .awaitingCalibration
    private var sent: [SessionEvent] = []

    override func setUp() {
        super.setUp()
        monitor = GPSHealthMonitor()
        state = .awaitingCalibration
        sent = []
    }

    // MARK: Helpers

    private func send(_ event: SessionEvent) {
        sent.append(event)
        state = SessionReducer.reduce(state, event, calibration: .precise).0
    }

    /// Runs the heartbeat from `from` to `to` against one fix, exactly as the coordinator does.
    private func beats(from: TimeInterval, to: TimeInterval,
                       fixTimestamp: TimeInterval, accuracy: Double) {
        var now = from
        while now <= to {
            if state.shouldPlayAudio || state == .awaitingCalibration,
               let event = monitor.check(now: now, fixTimestamp: fixTimestamp,
                                         horizontalAccuracy: accuracy,
                                         canDeliver: state.shouldPlayAudio, tuning: tuning) {
                send(event)
            }
            now += heartbeat
        }
    }

    private func fixAccepted(accuracy: Double) {
        if let event = monitor.fixAccepted(horizontalAccuracy: accuracy, tuning: tuning) {
            send(event)
        }
    }

    // MARK: Problem 1 — no latching while awaiting calibration

    func testWeakSpellDuringCalibrationPromptShowsBannerOnceRunning() {
        // 20 s of weak (25 m) fixes while the user hasn't calibrated yet — past the 15 s timeout.
        beats(from: 0, to: 20, fixTimestamp: 19.5, accuracy: 25)
        XCTAssertEqual(state, .awaitingCalibration)
        XCTAssertEqual(sent, [], "the reducer ignores complaints here, so none may be spent")
        XCTAssertNil(monitor.delivered)

        send(.calibrationBecameValid(.precise))
        beats(from: 20.04, to: 21, fixTimestamp: 20.5, accuracy: 25)

        XCTAssertEqual(state, .degraded(reason: .accuracyPoor))
        XCTAssertEqual(sent.filter { $0 == .gpsAccuracyPoor }.count, 1)
    }

    func testStalenessDuringCalibrationPromptShowsBannerOnceRunning() {
        beats(from: 0, to: 10, fixTimestamp: 0, accuracy: 5)        // 10 s without a fix
        XCTAssertEqual(sent, [])

        send(.calibrationBecameValid(.precise))
        beats(from: 10.04, to: 11, fixTimestamp: 0, accuracy: 5)
        XCTAssertEqual(state, .degraded(reason: .gpsLost))
    }

    // MARK: Problem 2 — accuracyPoor escalates to gpsLost

    func testAccuracyPoorThenStalenessReachesGPSLost() {
        state = .running(quality: .precise)
        beats(from: 0, to: 16, fixTimestamp: 16, accuracy: 25)
        XCTAssertEqual(state, .degraded(reason: .accuracyPoor))

        // Fixes stop entirely: the last weak one, at t = 16, goes stale at t = 24.
        beats(from: 16.04, to: 30, fixTimestamp: 16, accuracy: 25)
        XCTAssertEqual(state, .degraded(reason: .gpsLost))
        XCTAssertEqual(sent, [.gpsAccuracyPoor, .gpsWentStale])
    }

    func testGPSLostDoesNotDowngradeToAccuracyPoor() {
        state = .running(quality: .precise)
        beats(from: 0, to: 9, fixTimestamp: 0, accuracy: 25)
        XCTAssertEqual(state, .degraded(reason: .gpsLost))

        // Weak fixes resume for a long time: still lost until a strong fix arrives.
        beats(from: 9.04, to: 30, fixTimestamp: 29.9, accuracy: 25)
        XCTAssertEqual(sent, [.gpsWentStale])
    }

    // MARK: Exactly once per complaint

    func testEachComplaintIsSentOnce() {
        state = .running(quality: .precise)
        beats(from: 0, to: 60, fixTimestamp: 59.9, accuracy: 25)     // 60 s of weak heartbeats
        XCTAssertEqual(sent, [.gpsAccuracyPoor])

        beats(from: 60.04, to: 120, fixTimestamp: 60, accuracy: 25)  // then 60 s stale
        XCTAssertEqual(sent, [.gpsAccuracyPoor, .gpsWentStale])
    }

    // MARK: Recovery

    func testWeakFixesDoNotClearAccuracyPoor() {
        state = .running(quality: .precise)
        beats(from: 0, to: 16, fixTimestamp: 16, accuracy: 25)
        fixAccepted(accuracy: 25)
        fixAccepted(accuracy: 20)
        XCTAssertEqual(state, .degraded(reason: .accuracyPoor))
        XCTAssertEqual(monitor.delivered, .accuracyPoor)
    }

    func testStrongFixRecoversAndComplaintsCanFireAgain() {
        state = .running(quality: .precise)
        beats(from: 0, to: 9, fixTimestamp: 0, accuracy: 5)
        XCTAssertEqual(state, .degraded(reason: .gpsLost))

        fixAccepted(accuracy: 5)
        XCTAssertEqual(state, .running(quality: .precise))
        XCTAssertNil(monitor.delivered)
        fixAccepted(accuracy: 5)
        XCTAssertEqual(sent, [.gpsWentStale, .gpsRecovered], "recovery is sent once")

        beats(from: 9.04, to: 20, fixTimestamp: 9.04, accuracy: 5)
        XCTAssertEqual(state, .degraded(reason: .gpsLost), "a second outage complains again")
        XCTAssertEqual(sent, [.gpsWentStale, .gpsRecovered, .gpsWentStale])
    }

    func testStrongFixRestartsTheWeakTimer() {
        state = .running(quality: .precise)
        beats(from: 0, to: 10, fixTimestamp: 10, accuracy: 25)
        fixAccepted(accuracy: 5)
        XCTAssertNil(monitor.poorAccuracySince)

        beats(from: 10.04, to: 20, fixTimestamp: 20, accuracy: 25)   // only 10 s since the reset
        XCTAssertEqual(sent, [])
    }

    func testResetClearsEverything() {
        state = .running(quality: .precise)
        beats(from: 0, to: 16, fixTimestamp: 16, accuracy: 25)
        monitor.reset()
        XCTAssertNil(monitor.delivered)
        XCTAssertNil(monitor.poorAccuracySince)
    }
}
