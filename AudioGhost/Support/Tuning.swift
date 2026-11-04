import Foundation

/// Single source of truth for every tuning constant (spec §12).
///
/// Read them as `Tuning.current.tauMin`. Each default is declared exactly once, right here, so
/// "reset to spec defaults" is just `Tuning.current = Tuning()`. `current` is a `var` so the Debug
/// HUD can override values live in the field without a rebuild — that is the whole point of the
/// table in §12. Overrides persist across launches.
///
/// Written from the main queue (HUD sliders), read from the tracking queue; these are all plain
/// scalars and a torn read is not possible for `Double`/`Int` on ARM64, so no lock is used.
struct Tuning {

    /// The live values.
    static var current = Tuning()

    // MARK: Listener

    /// Ear height above the ground the listener is standing on. Ghost `up` is measured from here.
    var listenerEarHeight: Double = 1.6

    // MARK: GPS smoothing (§5.3)

    /// Smoothing time constant at ≤5 m accuracy. Raise if the HUD raw-vs-smoothed delta is jittery.
    var tauMin: Double = 1.0
    /// Smoothing time constant at ≥30 m accuracy. Lower if the source lags behind turns.
    var tauMax: Double = 3.0
    /// Fixes worse than this are rejected outright.
    var maxAcceptableAccuracy: Double = 30
    /// Fixes older than this (seconds) are rejected outright.
    var maxFixAge: Double = 5
    /// A jump further than this from the smoothed position is treated as suspect…
    var teleportDistance: Double = 20
    /// …until this many consecutive suspect fixes, at which point the filter snaps to raw.
    var teleportCount: Int = 3
    /// Max speed used for dead-reckoning between fixes.
    var maxFixSpeed: Double = 3.0
    /// Dead reckoning is frozen after this much time without a fix.
    var deadReckonMax: Double = 1.5
    /// Beyond this the session is `degraded(.gpsLost)`.
    var gpsStaleTimeout: Double = 8.0
    /// Accepted fixes worse than this are "weak" — usable, but worth telling the user about.
    var weakAccuracy: Double = 15
    /// Weak (or entirely absent) fixes sustained for this long ⇒ `degraded(.accuracyPoor)`.
    var accuracyPoorTimeout: Double = 15.0
    /// "Drop here" is enabled at or below this accuracy (override allowed with a warning).
    var dropHereAccuracy: Double = 10

    // MARK: Near-field clamp (§5.6)

    /// Never render the ghost closer than this, regardless of geometry.
    var nearFieldFloor: Double = 4.0
    /// Wrap-aware bearing low-pass inside the clamp. Lower = more responsive, more orbiting.
    var nearFieldBearingTau: Double = 3.0
    /// Leave the clamp only past `rMin * this` — hysteresis against boundary flapping.
    var clampExitFactor: Double = 1.25

    // MARK: Calibration & drift (§6.3, §6.4)

    /// Below this speed GPS course is noise.
    var courseMinSpeed: Double = 0.8
    /// Course fixes worse than this (degrees) are ignored.
    var maxCourseAccuracy: Double = 25
    /// Course-vs-head disagreement beyond this is a head turn, not drift — don't corrupt the offset.
    var courseGateAngle: Double = (60.0).radians
    /// Per-fix correction gain. 0.02 @ 1 Hz ⇒ ~10° of drift removed in 2–3 minutes of walking.
    var courseGain: Double = 0.02
    /// Distance of valid-course walking needed to cold-start a `.coarse` calibration.
    var coarseSeedDistance: Double = 15
    /// Sustained course error above this suggests recalibrating.
    var recalibrateHintError: Double = (25.0).radians
    /// Ritual gates.
    var calibrationSampleDuration: Double = 2.0
    var calibrationMaxHeadingAccuracy: Double = 15
    var calibrationMaxHeadingSpread: Double = (5.0).radians
    var calibrationMaxAttitudeSpread: Double = (3.0).radians

    // MARK: Head tracking

    /// No motion sample for this long while "connected" ⇒ stalled; restart updates.
    var motionStaleTimeout: Double = 0.5

    // MARK: UI

    /// Rate at which tracking-queue snapshots are published to the UI.
    var uiSnapshotHz: Double = 4
}

// MARK: - Live overrides

extension Tuning {

    /// One Debug HUD slider. `key` is the persisted name — renaming one drops that saved override.
    struct Knob: Identifiable {
        var id: String { key }
        let key: String
        let label: String
        let range: ClosedRange<Double>
        let path: WritableKeyPath<Tuning, Double>
        /// Displayed in degrees rather than radians.
        var isAngle: Bool = false
    }

    static let knobs: [Knob] = [
        Knob(key: "listenerEarHeight", label: "Ear height (m)", range: 1.0...2.2, path: \.listenerEarHeight),
        Knob(key: "tauMin", label: "τ min (s)", range: 0.2...3, path: \.tauMin),
        Knob(key: "tauMax", label: "τ max (s)", range: 0.5...8, path: \.tauMax),
        Knob(key: "maxAcceptableAccuracy", label: "Max accuracy (m)", range: 10...60, path: \.maxAcceptableAccuracy),
        Knob(key: "teleportDistance", label: "Teleport dist (m)", range: 5...60, path: \.teleportDistance),
        Knob(key: "deadReckonMax", label: "Dead reckon (s)", range: 0...4, path: \.deadReckonMax),
        Knob(key: "gpsStaleTimeout", label: "GPS stale (s)", range: 2...20, path: \.gpsStaleTimeout),
        Knob(key: "nearFieldFloor", label: "Near-field floor (m)", range: 1...15, path: \.nearFieldFloor),
        Knob(key: "nearFieldBearingTau", label: "Near-field τ (s)", range: 0.5...10, path: \.nearFieldBearingTau),
        Knob(key: "clampExitFactor", label: "Clamp exit ×", range: 1.0...2.0, path: \.clampExitFactor),
        Knob(key: "courseMinSpeed", label: "Course min speed (m/s)", range: 0.2...3, path: \.courseMinSpeed),
        Knob(key: "courseGateAngle", label: "Course gate (°)", range: (10.0).radians...(120.0).radians,
             path: \.courseGateAngle, isAngle: true),
        Knob(key: "courseGain", label: "Course gain", range: 0...0.2, path: \.courseGain),
    ]

    private static let storageKey = "Tuning.overrides.v1"

    static func loadOverrides(from defaults: UserDefaults = .standard) {
        guard let table = defaults.dictionary(forKey: storageKey) as? [String: Double] else { return }
        for knob in knobs {
            if let value = table[knob.key] { current[keyPath: knob.path] = value }
        }
    }

    static func saveOverrides(to defaults: UserDefaults = .standard) {
        var table: [String: Double] = [:]
        for knob in knobs { table[knob.key] = current[keyPath: knob.path] }
        defaults.set(table, forKey: storageKey)
    }

    static func resetOverrides(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        current = Tuning()
    }
}
