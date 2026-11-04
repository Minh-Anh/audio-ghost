import Foundation
import PHASE
import AVFAudio
import simd

/// What the renderer actually did this tick — surfaced on the Debug HUD and written to the CSV.
struct RenderState: Equatable {
    var clampActive = false
    var trueDistance: Double = 0
    var renderedDistance: Double = 0
    var bearing: Double = 0            // radians cw from north, listener → ghost
    var renderedBearing: Double = 0
    var elevation: Double = 0          // meters, ghost above ear level
    var isPlaying = false
}

enum SpatialAudioError: LocalizedError {
    case assetLoad(String)
    case pipelineUnavailable
    case eventCreation(String)

    var errorDescription: String? {
        switch self {
        case .assetLoad(let m): return "Couldn't load the ghost's audio (\(m)). Re-import the file."
        case .pipelineUnavailable: return "The spatial audio pipeline couldn't be created."
        case .eventCreation(let m): return "Couldn't start the sound (\(m))."
        }
    }
}

/// PHASE graph and lifecycle (spec §7). Every call must happen on the tracking queue — PHASE's
/// thread-safety is undocumented, so single-queue discipline is the design regardless (§3.3).
///
/// The near-field clamp (§5.6) lives here, at the boundary, because it is a *rendering* decision:
/// it moves the source's rendered transform, never the world model.
final class SpatialAudioEngine {

    /// The built PHASE graph; all of it exists or none of it does.
    private struct Graph {
        let engine: PHASEEngine
        let listener: PHASEListener
        let source: PHASESource
        let mixerID: String
        let soundAssetID: String
        let eventAssetID: String
    }

    private var graph: Graph?
    private var event: PHASESoundEvent?

    /// Ghost position in session ENU (x: east, y: north, z: up relative to ear level).
    private var ghostENU: SIMD3<Double> = .zero

    // Near-field clamp state
    private var clampActive = false
    private var smoothedBearing: Double = 0
    private var lastTickTime: TimeInterval?

    // MARK: Setup

    /// Builds the graph and starts the looping event.
    func start(ghost: Ghost, audioURL: URL, ghostENU: SIMD3<Double>, frameConfig: FrameConfig) throws {
        stop()

        self.ghostENU = ghostENU
        smoothedBearing = atan2Bearing(east: ghostENU.x, north: ghostENU.y)
        clampActive = false
        lastTickTime = nil

        let engine = PHASEEngine(updateMode: .automatic)
        // Keep the world in meters/seconds so ENU values can be handed over untouched.
        engine.unitsPerMeter = 1
        engine.unitsPerSecond = 1

        let listener = PHASEListener(engine: engine)
        listener.transform = matrix_identity_float4x4
        if #available(iOS 18.0, *) {
            // SPEC CORRECTION (§7.2): the OS-level head-tracked spatialization that would fight our
            // own listener rotation is controlled right here, per listener. We drive the listener
            // from CMHeadphoneMotionManager ourselves, so PHASE must not also rotate it.
            listener.automaticHeadTrackingFlags = []
        }
        try engine.rootObject.addChild(listener)

        let source = PHASESource(engine: engine)
        source.transform = Quat.transform(rotation: .identityRotation,
                                          position: Frames.phasePosition(ghostENU, cfg: frameConfig))
        try engine.rootObject.addChild(source)

        let soundAssetID = "asset-\(ghost.id.uuidString)"
        let eventAssetID = "event-\(ghost.id.uuidString)"

        do {
            _ = try engine.assetRegistry.registerSoundAsset(
                url: audioURL,
                identifier: soundAssetID,
                assetType: .resident,          // files are capped at 20 min by AudioImport
                channelLayout: nil,
                normalizationMode: .dynamic)
        } catch {
            throw SpatialAudioError.assetLoad(error.localizedDescription)
        }

        guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission]) else {
            throw SpatialAudioError.pipelineUnavailable
        }
        let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
        let distance = PHASEGeometricSpreadingDistanceModelParameters()
        distance.rolloffFactor = ghost.rolloffFactor
        distance.fadeOutParameters = PHASEDistanceModelFadeOutParameters(cullDistance: ghost.cullDistance)
        mixer.distanceModelParameters = distance

        let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: soundAssetID,
                                                 mixerDefinition: mixer)
        sampler.playbackMode = .looping
        sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: ghost.referenceLevelDB)

        do {
            _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler,
                                                                 identifier: eventAssetID)
        } catch {
            throw SpatialAudioError.assetLoad(error.localizedDescription)
        }

        try engine.start()

        let graph = Graph(engine: engine, listener: listener, source: source, mixerID: mixer.identifier,
                          soundAssetID: soundAssetID, eventAssetID: eventAssetID)
        self.graph = graph
        do {
            try startEvent(in: graph)
        } catch {
            throw SpatialAudioError.eventCreation(error.localizedDescription)
        }
        Log.info("SpatialAudioEngine started for ghost \(ghost.name)")
    }

    func stop() {
        pauseEvent()
        guard let graph else { return }
        graph.engine.stop()
        graph.engine.assetRegistry.unregisterAsset(identifier: graph.soundAssetID, completion: nil)
        graph.engine.assetRegistry.unregisterAsset(identifier: graph.eventAssetID, completion: nil)
        self.graph = nil
    }

    /// Pause: stop the event but keep the engine and registered assets, so resuming is cheap
    /// (interruptions, AirPods out, non-headphone route — spec §7.1, §6.7).
    func pauseEvent() {
        event?.stopAndInvalidate()
        event = nil
    }

    /// Recreates and restarts the event after a pause. Returns false if the graph is gone entirely.
    @discardableResult
    func resumeEvent() -> Bool {
        if event != nil { return true }
        guard let graph else { return false }
        do {
            // An interruption can leave the engine itself stopped once the audio session is torn
            // down and reactivated, so bring it back before rebuilding the event.
            if graph.engine.renderingState != .started {
                try graph.engine.start()
            }
            try startEvent(in: graph)
            return true
        } catch {
            Log.error("Failed to resume sound event: \(error.localizedDescription)")
            return false
        }
    }

    /// A stopped `PHASESoundEvent` can't be restarted, so every (re)start builds a new one.
    private func startEvent(in graph: Graph) throws {
        let params = PHASEMixerParameters()
        params.addSpatialMixerParameters(identifier: graph.mixerID, source: graph.source, listener: graph.listener)
        let event = try PHASESoundEvent(engine: graph.engine, assetIdentifier: graph.eventAssetID,
                                        mixerParameters: params)
        self.event = event
        event.start(completion: nil)
    }

    // MARK: Per-tick update

    /// Updates the listener transform and — inside the near-field clamp — the source transform.
    /// Runs before the graph exists too, so the HUD has geometry to show before audio starts.
    func updateListener(pose: ListenerPose, now: TimeInterval, frameConfig cfg: FrameConfig) -> RenderState {
        let isFirstTick = lastTickTime == nil
        let dt = lastTickTime.map { max(0, now - $0) } ?? 0
        lastTickTime = now

        let rel = ghostENU - pose.enuPosition
        let r = Geo.horizontalLength(rel)
        let trueBearing = r > 1e-6 ? atan2Bearing(east: rel.x, north: rel.y) : smoothedBearing
        // On the very first tick there is no history to filter against: seed the bearing with the
        // truth, or the filter spends its first seconds sweeping in from a stale value.
        if isFirstTick { smoothedBearing = trueBearing }

        // §5.6 near-field clamp with hysteresis. rMin grows with GPS uncertainty: inside the noise
        // the true geometry is meaningless and would whip the source around the head.
        let rMin = max(Tuning.current.nearFieldFloor, pose.horizontalAccuracy)
        clampActive = clampActive ? r <= rMin * Tuning.current.clampExitFactor : r < rMin

        var renderRel = rel                          // z stays: the true height survives the clamp
        if clampActive {
            smoothedBearing = lowpassAngle(current: smoothedBearing, target: trueBearing,
                                           tau: Tuning.current.nearFieldBearingTau, dt: dt)
            let dir = bearingToUnitENU(smoothedBearing)
            renderRel.x = rMin * dir.east
            renderRel.y = rMin * dir.north
        } else {
            smoothedBearing = trueBearing
        }

        graph?.listener.transform = Quat.transform(rotation: pose.headOrientationPHASE,
                                                   position: Frames.phasePosition(pose.enuPosition, cfg: cfg))

        // The source transform is static except in the clamp regime — the one documented exception.
        let sourceENU = clampActive ? pose.enuPosition + renderRel : ghostENU
        graph?.source.transform = Quat.transform(rotation: .identityRotation,
                                                 position: Frames.phasePosition(sourceENU, cfg: cfg))

        return RenderState(clampActive: clampActive,
                           trueDistance: simd_length(rel),
                           renderedDistance: simd_length(renderRel),
                           bearing: trueBearing,
                           renderedBearing: clampActive ? smoothedBearing : trueBearing,
                           elevation: rel.z,
                           isPlaying: event != nil)
    }

    /// Called when the ghost's position becomes known (the session's first accepted fix).
    func setGhostENU(_ enu: SIMD3<Double>) {
        ghostENU = enu
    }
}
