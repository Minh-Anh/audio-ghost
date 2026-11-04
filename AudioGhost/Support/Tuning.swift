import Foundation

/// Single source of truth for every tuning constant (spec §12).
///
/// These are `var`s, not `let`s, so the Debug HUD can override them live in the field without a
/// rebuild — that is the whole point of the table in §12. Overrides persist across launches.
/// Written from the main actor (HUD sliders), read from the tracking queue; they are plain
/// scalars and a torn read is not possible for `Double`/`Int` on ARM64, so no lock is used.
enum Tuning {

    // MARK: Listener

    /// Ear height above the ground the listener is standing on. Ghost `up` is measured from here.
    static var listenerEarHeight: Double = 1.6

    // MARK: GPS smoothing (§5.3)

    /// Smoothing time constant at ≤5 m accuracy. Raise if the HUD raw-vs-smoothed delta is jittery.
    static var tauMin: Double = 1.0
    /// Smoothing time constant at ≥30 m accuracy. Lower if the source lags behind turns.
    static var tauMax: Double = 3.0
    /// Fixes worse than this are rejected outright.
    static var maxAcceptableAccuracy: Double = 30
    /// A jump further than this from the smoothed position is treated as suspect…
    static var teleportDistance: Double = 20
    /// …until this many consecutive suspect fixes, at which point the filter snaps to raw.
    static var teleportCount: Int = 3
    /// Max speed used for dead-reckoning between fixes.
    static var maxFixSpeed: Double = 3.0
    /// Dead reckoning is frozen after this much time without a fix.
    static var deadReckonMax: Double = 1.5
    /// Beyond this the session is `degraded(.gpsLost)`.
    static var gpsStaleTimeout: Double = 8.0
    /// Accepted fixes worse than this are "weak" — usable, but worth telling the user about.
    static var weakAccuracy: Double = 15
    /// Weak (or entirely absent) fixes sustained for this long ⇒ `degraded(.accuracyPoor)`.
    static var accuracyPoorTimeout: Double = 15.0
    /// First-fix accuracy gate for seeding the session origin.
    static var originAccuracy: Double = 20
    /// "Drop here" is enabled at or below this accuracy (override allowed with a warning).
    static var dropHereAccuracy: Double = 10

    // MARK: Near-field clamp (§5.6)

    /// Never render the ghost closer than this, regardless of geometry.
    static var nearFieldFloor: Double = 4.0
    /// Wrap-aware bearing low-pass inside the clamp. Lower = more responsive, more orbiting.
    static var nearFieldBearingTau: Double = 3.0
    /// Leave the clamp only past `rMin * this` — hysteresis against boundary flapping.
    static var clampExitFactor: Double = 1.25

    // MARK: Calibration & drift (§6.3, §6.4)

    /// Below this speed GPS course is noise.
    static var courseMinSpeed: Double = 0.8
    /// Course fixes worse than this (degrees) are ignored.
    static var maxCourseAccuracy: Double = 25
    /// Course-vs-head disagreement beyond this is a head turn, not drift — don't corrupt the offset.
    static var courseGateAngle: Double = (60.0).radians
    /// Per-fix correction gain. 0.02 @ 1 Hz ⇒ ~10° of drift removed in 2–3 minutes of walking.
    static var courseGain: Double = 0.02
    /// Distance of valid-course walking needed to cold-start a `.coarse` calibration.
    static var coarseSeedDistance: Double = 15
    /// Sustained course error above this suggests recalibrating.
    static var recalibrateHintError: Double = (25.0).radians
    /// Ritual gates.
    static var calibrationSampleDuration: Double = 2.0
    static var calibrationMaxHeadingAccuracy: Double = 15
    static var calibrationMaxHeadingSpread: Double = (5.0).radians
    static var calibrationMaxAttitudeSpread: Double = (3.0).radians

    // MARK: Head tracking

    /// No motion sample for this long while "connected" ⇒ stalled; restart updates.
    static var motionStaleTimeout: Double = 0.5

    // MARK: Audio (§7.3)

    static var defaultRolloff: Double = 1.0
    static var defaultCullDistance: Double = 400

    // MARK: UI

    /// Rate at which tracking-queue snapshots are published to the UI.
    static var uiSnapshotHz: Double = 4

    // MARK: Persistence of field overrides

    private static let storageKey = "Tuning.overrides.v1"

    /// Every live-overridable constant, as a keyed table for the Debug HUD sliders.
    struct Knob: Identifiable {
        var id: String { key }
        let key: String
        let label: String
        let range: ClosedRange<Double>
        let get: () -> Double
        let set: (Double) -> Void
        /// Displayed in degrees rather than radians.
        var isAngle: Bool = false
    }

    static let knobs: [Knob] = [
        Knob(key: "listenerEarHeight", label: "Ear height (m)", range: 1.0...2.2,
             get: { listenerEarHeight }, set: { listenerEarHeight = $0 }),
        Knob(key: "tauMin", label: "τ min (s)", range: 0.2...3, get: { tauMin }, set: { tauMin = $0 }),
        Knob(key: "tauMax", label: "τ max (s)", range: 0.5...8, get: { tauMax }, set: { tauMax = $0 }),
        Knob(key: "maxAcceptableAccuracy", label: "Max accuracy (m)", range: 10...60,
             get: { maxAcceptableAccuracy }, set: { maxAcceptableAccuracy = $0 }),
        Knob(key: "teleportDistance", label: "Teleport dist (m)", range: 5...60,
             get: { teleportDistance }, set: { teleportDistance = $0 }),
        Knob(key: "deadReckonMax", label: "Dead reckon (s)", range: 0...4,
             get: { deadReckonMax }, set: { deadReckonMax = $0 }),
        Knob(key: "gpsStaleTimeout", label: "GPS stale (s)", range: 2...20,
             get: { gpsStaleTimeout }, set: { gpsStaleTimeout = $0 }),
        Knob(key: "nearFieldFloor", label: "Near-field floor (m)", range: 1...15,
             get: { nearFieldFloor }, set: { nearFieldFloor = $0 }),
        Knob(key: "nearFieldBearingTau", label: "Near-field τ (s)", range: 0.5...10,
             get: { nearFieldBearingTau }, set: { nearFieldBearingTau = $0 }),
        Knob(key: "clampExitFactor", label: "Clamp exit ×", range: 1.0...2.0,
             get: { clampExitFactor }, set: { clampExitFactor = $0 }),
        Knob(key: "courseMinSpeed", label: "Course min speed (m/s)", range: 0.2...3,
             get: { courseMinSpeed }, set: { courseMinSpeed = $0 }),
        Knob(key: "courseGateAngle", label: "Course gate (°)", range: (10.0).radians...120.0.radians,
             get: { courseGateAngle }, set: { courseGateAngle = $0 }, isAngle: true),
        Knob(key: "courseGain", label: "Course gain", range: 0...0.2,
             get: { courseGain }, set: { courseGain = $0 }),
    ]

    static func loadOverrides(from defaults: UserDefaults = .standard) {
        guard let table = defaults.dictionary(forKey: storageKey) as? [String: Double] else { return }
        for knob in knobs {
            if let v = table[knob.key] { knob.set(v) }
        }
    }

    static func saveOverrides(to defaults: UserDefaults = .standard) {
        var table: [String: Double] = [:]
        for knob in knobs { table[knob.key] = knob.get() }
        defaults.set(table, forKey: storageKey)
    }

    static func resetOverrides(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        listenerEarHeight = 1.6
        tauMin = 1.0; tauMax = 3.0
        maxAcceptableAccuracy = 30
        teleportDistance = 20; teleportCount = 3
        maxFixSpeed = 3.0; deadReckonMax = 1.5
        gpsStaleTimeout = 8.0; accuracyPoorTimeout = 15.0; weakAccuracy = 15
        nearFieldFloor = 4.0; nearFieldBearingTau = 3.0; clampExitFactor = 1.25
        courseMinSpeed = 0.8; maxCourseAccuracy = 25
        courseGateAngle = (60.0).radians; courseGain = 0.02
        motionStaleTimeout = 0.5
    }
}
