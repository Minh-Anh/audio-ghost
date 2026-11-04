import Foundation
import Observation

/// Debug-build affordances: desk simulation switches read by `SessionCoordinator` at session
/// start. The UI that changes them only appears when `isDebugBuild` is true, but the flags compile
/// everywhere so the coordinator stays free of conditional compilation in its own logic.
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

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
