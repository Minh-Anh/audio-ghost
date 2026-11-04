import Foundation

/// A sound anchored to a real-world coordinate (spec §4).
struct Ghost: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Ghost"
    var latitude: Double = 0            // WGS84 degrees
    var longitude: Double = 0
    /// Meters above the ground the *listener* is standing on (§5.4). Rendered height is
    /// `heightAboveGround − Tuning.listenerEarHeight`.
    var heightAboveGround: Double = 1.6
    /// Relative to Documents/Audio/
    var audioFileName: String = ""
    var rolloffFactor: Double = 1.0
    var cullDistance: Double = 400
    /// Per-ghost trim, dB, applied via PHASE's relative-SPL calibration.
    var referenceLevelDB: Double = 0
    /// Set by AudioImport, shown in the editor.
    var audioDuration: Double = 0
    var audioNote: String = ""

    var coordinate: Geo.Coordinate {
        get { Geo.Coordinate(latitude: latitude, longitude: longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }

    var hasAudio: Bool { !audioFileName.isEmpty }

    var hasPlacement: Bool { latitude != 0 || longitude != 0 }

    var isPlayable: Bool { hasAudio && hasPlacement }
}
