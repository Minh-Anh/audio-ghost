import Foundation
import simd

/// Everything the renderer needs to know about the listener, produced by pose fusion on the
/// tracking queue and consumed by `SpatialAudioEngine` (spec §3).
struct ListenerPose {
    /// Meters, East-North-Up, relative to the session origin.
    var enuPosition: SIMD3<Double>
    /// Final listener rotation in the PHASE world frame.
    var headOrientationPHASE: simd_quatf
    /// GPS-reported horizontal accuracy, meters. Drives the near-field clamp radius.
    var horizontalAccuracy: Double
    /// Uptime of the last headphone-motion sample.
    var motionTimestamp: TimeInterval

    /// Diagnostics carried alongside the pose for the HUD and the CSV.
    var attitudeYaw: Double = 0
    var trueYaw: Double = 0
    var pitch: Double = 0

    static let identity = ListenerPose(enuPosition: .zero,
                                       headOrientationPHASE: .identityRotation,
                                       horizontalAccuracy: 0,
                                       motionTimestamp: 0)
}
