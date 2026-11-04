import Foundation

// MARK: - State

enum DegradedReason: String, Equatable {
    case gpsLost, accuracyPoor

    var banner: String {
        switch self {
        case .gpsLost: return "GPS lost — holding the last position"
        case .accuracyPoor: return "GPS is weak here"
        }
    }
}

enum PauseReason: String, Equatable {
    case airpodsDisconnected, audioInterruption, routeNotHeadphones, userPaused

    var banner: String {
        switch self {
        case .airpodsDisconnected: return "AirPods disconnected"
        case .audioInterruption: return "Audio interrupted"
        case .routeNotHeadphones: return "Put your headphones back on"
        case .userPaused: return "Paused"
        }
    }
}

enum SessionError: Equatable {
    case locationPermission
    case motionPermission
    case noHeadTrackingAirPods
    case assetLoad(String)
    case audioEngine(String)
    case ghostIncomplete

    var message: String {
        switch self {
        case .locationPermission:
            return "AudioGhost needs location access to know where you are. Enable it in Settings."
        case .motionPermission:
            return "AudioGhost needs motion access to track your head orientation. Enable it in Settings."
        case .noHeadTrackingAirPods:
            return "Head tracking needs AirPods Pro, AirPods (3rd generation or later) or AirPods Max, connected and in your ears."
        case .assetLoad(let m):
            return "The ghost's audio couldn't be loaded (\(m)). Re-import the file."
        case .audioEngine(let m):
            return "The audio engine failed to start (\(m))."
        case .ghostIncomplete:
            return "This ghost needs an audio file and a location before it can play."
        }
    }

    var isPermissionProblem: Bool {
        switch self {
        case .locationPermission, .motionPermission: return true
        default: return false
        }
    }
}

enum SessionState: Equatable {
    case idle
    case acquiringFix
    case awaitingCalibration
    case running(quality: CalibrationQuality)
    case degraded(reason: DegradedReason)
    case paused(reason: PauseReason)
    case failed(SessionError)

    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// Audio should be sounding in these states. `degraded` deliberately keeps playing —
    /// going silent is worse than being slightly wrong (spec §8).
    var shouldPlayAudio: Bool {
        switch self {
        case .running, .degraded: return true
        default: return false
        }
    }

    var banner: String? {
        switch self {
        case .idle, .running: return nil
        case .acquiringFix: return "Waiting for a GPS fix…"
        case .awaitingCalibration: return "Calibrate to line the sound up with the world"
        case .degraded(let r): return r.banner
        case .paused(let r): return r.banner
        case .failed(let e): return e.message
        }
    }
}

// MARK: - Events

enum SessionEvent: Equatable {
    case startRequested
    case ghostInvalid
    case locationPermissionDenied
    case motionPermissionDenied
    case headTrackingUnavailable
    case firstFixAccepted                 // seeds the ENU origin
    case calibrationBecameValid(CalibrationQuality)
    case calibrationInvalidated
    case gpsWentStale
    case gpsAccuracyPoor
    case gpsRecovered
    case airpodsDisconnected
    case airpodsReconnected
    case audioInterrupted
    case audioInterruptionEnded(shouldResume: Bool)
    case routeLeftHeadphones
    case routeReturnedToHeadphones
    case userPaused
    case userResumed
    case assetLoadFailed(String)
    case audioEngineFailed(String)
    case stopRequested
}

// MARK: - Effects

enum SessionEffect: Equatable {
    case startServices
    case stopServices
    case startAudio
    case pauseAudio
    case resumeAudio
    case seedOrigin
    case invalidateCalibration
    case promptCalibration
    case log(String)
}

// MARK: - Reducer

/// Pure `reduce(state, event) → (state, [effects])` (spec §8). Every transition in the spec's
/// table has a unit test; the coordinator does nothing but feed this function and run its effects.
enum SessionReducer {

    static func reduce(_ state: SessionState,
                       _ event: SessionEvent,
                       calibration: CalibrationQuality) -> (SessionState, [SessionEffect]) {
        // Terminal failures and user stop are handled uniformly first.
        switch event {
        case .stopRequested:
            return (.idle, [.stopServices])
        case .locationPermissionDenied:
            return (.failed(.locationPermission), [.stopServices])
        case .motionPermissionDenied:
            return (.failed(.motionPermission), [.stopServices])
        case .headTrackingUnavailable:
            return (.failed(.noHeadTrackingAirPods), [.stopServices])
        case .assetLoadFailed(let m):
            return (.failed(.assetLoad(m)), [.stopServices])
        case .audioEngineFailed(let m):
            return (.failed(.audioEngine(m)), [.stopServices])
        case .ghostInvalid:
            return (.failed(.ghostIncomplete), [])
        default:
            break
        }

        switch (state, event) {

        case (.idle, .startRequested):
            return (.acquiringFix, [.startServices])

        case (.acquiringFix, .firstFixAccepted):
            // This fix seeds the ENU origin. Audio starts now even before calibration: an
            // unaligned ghost is still useful feedback, and course seeding may fix it hands-free.
            if calibration == .none {
                return (.awaitingCalibration, [.seedOrigin, .startAudio, .promptCalibration])
            }
            return (.running(quality: calibration), [.seedOrigin, .startAudio])

        case (.awaitingCalibration, .calibrationBecameValid(let q)):
            return (.running(quality: q), [.log("calibration \(q.rawValue)")])

        case (.running, .calibrationBecameValid(let q)):
            return (.running(quality: q), [])

        case (.running, .calibrationInvalidated),
             (.degraded, .calibrationInvalidated):
            return (.awaitingCalibration, [.promptCalibration])

        // GPS health — audio keeps playing throughout.
        case (.running, .gpsWentStale):
            return (.degraded(reason: .gpsLost), [.log("gps stale")])
        case (.running, .gpsAccuracyPoor):
            return (.degraded(reason: .accuracyPoor), [.log("gps weak")])
        case (.degraded, .gpsRecovered):
            return (.running(quality: calibration), [.log("gps recovered")])
        case (.degraded(.accuracyPoor), .gpsWentStale):
            return (.degraded(reason: .gpsLost), [])
        case (.awaitingCalibration, .gpsWentStale),
             (.awaitingCalibration, .gpsAccuracyPoor):
            return (state, [])                       // not yet calibrated; the banner already says so

        // Pauses.
        case (_, .airpodsDisconnected) where state.isActive:
            return (.paused(reason: .airpodsDisconnected), [.pauseAudio, .invalidateCalibration])
        case (_, .audioInterrupted) where state.isActive:
            return (.paused(reason: .audioInterruption), [.pauseAudio])
        case (_, .routeLeftHeadphones) where state.isActive:
            return (.paused(reason: .routeNotHeadphones), [.pauseAudio])
        case (_, .userPaused) where state.isActive:
            return (.paused(reason: .userPaused), [.pauseAudio])

        // Recoveries — each only from its matching pause reason.
        case (.paused(.airpodsDisconnected), .airpodsReconnected),
             (.paused(.routeNotHeadphones), .routeReturnedToHeadphones),
             (.paused(.userPaused), .userResumed):
            return resume(calibration: calibration)
        case (.paused(.audioInterruption), .audioInterruptionEnded(let shouldResume)):
            return shouldResume ? resume(calibration: calibration)
                                : (.paused(reason: .userPaused), [])

        default:
            return (state, [])
        }
    }

    private static func resume(calibration: CalibrationQuality) -> (SessionState, [SessionEffect]) {
        if calibration == .none {
            return (.awaitingCalibration, [.resumeAudio, .promptCalibration])
        }
        return (.running(quality: calibration), [.resumeAudio])
    }
}
