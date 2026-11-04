import Foundation
import Observation

/// Holds the measured `FrameConfig` and persists it.
///
/// The UI observes it; the tracking queue reads `config` on every heartbeat. Reads therefore go
/// through a lock-guarded copy rather than the observable property, so background reads never
/// touch SwiftUI's observation machinery.
@Observable
final class FrameConfigStore {

    private let defaults: UserDefaults
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cached: FrameConfig

    /// Main-queue / UI facing.
    var observed: FrameConfig {
        didSet {
            lock.lock(); cached = observed; lock.unlock()
            observed.save(to: defaults)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = FrameConfig.load(from: defaults)
        self.observed = loaded
        self.cached = loaded
    }

    /// Thread-safe snapshot for the tracking queue.
    var config: FrameConfig {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    func update(_ transform: (inout FrameConfig) -> Void) {
        var copy = observed
        transform(&copy)
        observed = copy
    }
}
