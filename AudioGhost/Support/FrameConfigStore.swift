import Foundation
import Observation

/// Holds the measured `FrameConfig` and persists it to `UserDefaults`.
///
/// The UI observes `observed`; the tracking queue reads `config` on every heartbeat. Reads go
/// through a lock-guarded copy rather than the observable property, so background reads never
/// touch SwiftUI's observation machinery.
@Observable
final class FrameConfigStore {

    /// Holds the frame FrameProbe measured on the device. Changing this key discards it.
    private static let storageKey = "FrameConfig.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cached: FrameConfig

    /// Main-queue / UI facing.
    var observed: FrameConfig {
        didSet {
            lock.withLock { cached = observed }
            if let data = try? JSONEncoder().encode(observed) {
                defaults.set(data, forKey: Self.storageKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(FrameConfig.self, from: $0) } ?? FrameConfig()
        self.observed = loaded
        self.cached = loaded
    }

    /// Thread-safe snapshot for the tracking queue.
    var config: FrameConfig { lock.withLock { cached } }
}
