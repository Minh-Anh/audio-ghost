import Foundation
import Observation

/// Composition root. No singletons — everything is created here and injected through the
/// SwiftUI environment (spec §17).
@Observable
final class AppEnvironment {

    let store: GhostStore
    let debug: DebugSettings
    let frames: FrameConfigStore
    let session: SessionCoordinator

    init() {
        Tuning.loadOverrides()
        let store = GhostStore()
        let debug = DebugSettings()
        let frames = FrameConfigStore()
        self.store = store
        self.debug = debug
        self.frames = frames
        self.session = SessionCoordinator(store: store, debug: debug, frames: frames)
    }

    /// The MVP shows exactly one ghost; the store is already built for N.
    var ghost: Ghost? { store.ghosts.first }
}
