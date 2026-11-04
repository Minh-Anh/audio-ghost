import XCTest
@testable import AudioGhost

/// Every transition in the §8 table.
final class ReducerTests: XCTestCase {

    private func reduce(_ state: SessionState, _ event: SessionEvent,
                        calibration: CalibrationQuality = .none) -> (SessionState, [SessionEffect]) {
        SessionReducer.reduce(state, event, calibration: calibration)
    }

    // MARK: Happy path

    func testStartGoesToAcquiringFix() {
        let (state, effects) = reduce(.idle, .startRequested)
        XCTAssertEqual(state, .acquiringFix)
        XCTAssertEqual(effects, [.startServices])
    }

    func testFirstFixStartsAudioAwaitingCalibration() {
        let (state, effects) = reduce(.acquiringFix, .firstFixAccepted)
        XCTAssertEqual(state, .awaitingCalibration)
        XCTAssertEqual(effects, [.startAudio, .promptCalibration])
    }

    func testFirstFixWithExistingCalibrationRunsImmediately() {
        let (state, effects) = reduce(.acquiringFix, .firstFixAccepted, calibration: .precise)
        XCTAssertEqual(state, .running(quality: .precise))
        XCTAssertEqual(effects, [.startAudio])
    }

    func testRitualSuccessStartsRunningPrecise() {
        let (state, _) = reduce(.awaitingCalibration, .calibrationBecameValid(.precise))
        XCTAssertEqual(state, .running(quality: .precise))
    }

    func testCourseSeedStartsRunningCoarse() {
        let (state, _) = reduce(.awaitingCalibration, .calibrationBecameValid(.coarse))
        XCTAssertEqual(state, .running(quality: .coarse))
    }

    func testQualityUpgradeWhileRunning() {
        let (state, _) = reduce(.running(quality: .coarse), .calibrationBecameValid(.precise))
        XCTAssertEqual(state, .running(quality: .precise))
    }

    // MARK: GPS health

    func testRunningToDegradedOnStaleGps() {
        let (state, _) = reduce(.running(quality: .precise), .gpsWentStale)
        XCTAssertEqual(state, .degraded(reason: .gpsLost))
        XCTAssertTrue(state.shouldPlayAudio, "degraded keeps playing — silence is worse")
    }

    func testRunningToDegradedOnPoorAccuracy() {
        let (state, _) = reduce(.running(quality: .precise), .gpsAccuracyPoor)
        XCTAssertEqual(state, .degraded(reason: .accuracyPoor))
    }

    func testDegradedRecoversToRunningWithCurrentQuality() {
        let (state, _) = reduce(.degraded(reason: .gpsLost), .gpsRecovered, calibration: .coarse)
        XCTAssertEqual(state, .running(quality: .coarse))
    }

    func testDegradedAccuracyCanWorsenToGpsLost() {
        let (state, _) = reduce(.degraded(reason: .accuracyPoor), .gpsWentStale)
        XCTAssertEqual(state, .degraded(reason: .gpsLost))
    }

    func testGpsEventsDoNotDisturbAwaitingCalibration() {
        XCTAssertEqual(reduce(.awaitingCalibration, .gpsWentStale).0, .awaitingCalibration)
        XCTAssertEqual(reduce(.awaitingCalibration, .gpsAccuracyPoor).0, .awaitingCalibration)
    }

    // MARK: Pauses and recoveries

    func testAirpodsDisconnectPausesAndInvalidatesCalibration() {
        let (state, effects) = reduce(.running(quality: .precise), .airpodsDisconnected)
        XCTAssertEqual(state, .paused(reason: .airpodsDisconnected))
        XCTAssertEqual(effects, [.pauseAudio, .invalidateCalibration])
    }

    func testAirpodsReconnectWithNoCalibrationReturnsToAwaitingCalibration() {
        let (state, effects) = reduce(.paused(reason: .airpodsDisconnected), .airpodsReconnected,
                                      calibration: .none)
        XCTAssertEqual(state, .awaitingCalibration)
        XCTAssertEqual(effects, [.resumeAudio, .promptCalibration])
    }

    func testAirpodsReconnectWithCoarseReseedResumesRunning() {
        let (state, effects) = reduce(.paused(reason: .airpodsDisconnected), .airpodsReconnected,
                                      calibration: .coarse)
        XCTAssertEqual(state, .running(quality: .coarse))
        XCTAssertEqual(effects, [.resumeAudio])
    }

    func testInterruptionPausesAndAutoResumesWhenAllowed() {
        let (paused, effects) = reduce(.running(quality: .precise), .audioInterrupted)
        XCTAssertEqual(paused, .paused(reason: .audioInterruption))
        XCTAssertEqual(effects, [.pauseAudio])

        let (resumed, _) = reduce(paused, .audioInterruptionEnded(shouldResume: true),
                                  calibration: .precise)
        XCTAssertEqual(resumed, .running(quality: .precise))
    }

    func testInterruptionWithoutShouldResumeStaysPaused() {
        let (state, _) = reduce(.paused(reason: .audioInterruption),
                                .audioInterruptionEnded(shouldResume: false), calibration: .precise)
        XCTAssertEqual(state, .paused(reason: .userPaused))
    }

    func testRouteLeavingHeadphonesPauses() {
        let (state, effects) = reduce(.running(quality: .precise), .routeLeftHeadphones)
        XCTAssertEqual(state, .paused(reason: .routeNotHeadphones))
        XCTAssertEqual(effects, [.pauseAudio])
        let (resumed, _) = reduce(state, .routeReturnedToHeadphones, calibration: .precise)
        XCTAssertEqual(resumed, .running(quality: .precise))
    }

    func testUserPauseAndResume() {
        let (paused, _) = reduce(.running(quality: .precise), .userPaused)
        XCTAssertEqual(paused, .paused(reason: .userPaused))
        XCTAssertFalse(paused.shouldPlayAudio)
        let (resumed, _) = reduce(paused, .userResumed, calibration: .precise)
        XCTAssertEqual(resumed, .running(quality: .precise))
    }

    func testRecoveryOnlyFiresForTheMatchingReason() {
        // A route change must not un-pause an AirPods disconnect.
        let (state, _) = reduce(.paused(reason: .airpodsDisconnected), .routeReturnedToHeadphones,
                                calibration: .precise)
        XCTAssertEqual(state, .paused(reason: .airpodsDisconnected))
    }

    // MARK: Failures

    func testUnrecoverableFailures() {
        XCTAssertEqual(reduce(.acquiringFix, .locationPermissionDenied).0, .failed(.locationPermission))
        XCTAssertEqual(reduce(.acquiringFix, .motionPermissionDenied).0, .failed(.motionPermission))
        XCTAssertEqual(reduce(.acquiringFix, .headTrackingUnavailable).0, .failed(.noHeadTrackingAirPods))
        XCTAssertEqual(reduce(.running(quality: .precise), .assetLoadFailed("boom")).0,
                       .failed(.assetLoad("boom")))
        XCTAssertEqual(reduce(.idle, .ghostInvalid).0, .failed(.ghostIncomplete))
    }

    func testStopAlwaysReturnsToIdle() {
        for state: SessionState in [.acquiringFix, .awaitingCalibration, .running(quality: .precise),
                                    .degraded(reason: .gpsLost), .paused(reason: .userPaused),
                                    .failed(.locationPermission)] {
            let (next, effects) = reduce(state, .stopRequested)
            XCTAssertEqual(next, .idle, "from \(state)")
            XCTAssertEqual(effects, [.stopServices])
        }
    }

    func testFailedStateIsNotActiveAndDoesNotPlay() {
        let failed = SessionState.failed(.noHeadTrackingAirPods)
        XCTAssertFalse(failed.isActive)
        XCTAssertFalse(failed.shouldPlayAudio)
        XCTAssertNotNil(failed.banner)
    }

    func testEventsInIdleAreIgnored() {
        XCTAssertEqual(reduce(.idle, .firstFixAccepted).0, .idle)
        XCTAssertEqual(reduce(.idle, .airpodsDisconnected).0, .idle)
        XCTAssertEqual(reduce(.idle, .gpsWentStale).0, .idle)
    }
}
