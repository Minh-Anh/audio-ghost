import Foundation
import Observation

/// Debug-build affordances: desk simulation, frame sign flips, tuning overrides.
/// None of this is reachable in a release build (`AppEnvironment` only creates the debug UI
/// under `#if DEBUG`), but the flags themselves compile everywhere so the coordinator stays
/// free of conditional compilation in its own logic.
@Observable
final class DebugSettings {

    /// Use the synthetic head-pose provider instead of real AirPods (simulator / no AirPods).
    var useSyntheticHeadTracking = false
    /// Play a scripted GPS path instead of CoreLocation.
    var scriptedPath: ScriptedLocationProvider.Path?
    /// Injected GPS noise for the scripted provider.
    var scriptedNoiseSigma: Double = 4
    var scriptedReportedAccuracy: Double = 8
    /// Don't refuse to start when the route isn't headphones (desk testing on speakers).
    var allowNonHeadphoneRoute = false

    var isSimulating: Bool { useSyntheticHeadTracking || scriptedPath != nil }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
