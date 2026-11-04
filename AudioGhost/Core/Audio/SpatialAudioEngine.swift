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

    private let queue: DispatchQueue

    private var engine: PHASEEngine?
    private var listener: PHASEListener?
    private var source: PHASESource?
    private var event: PHASESoundEvent?
    private var soundAssetID = ""
    private var eventAssetID = ""

    /// Ghost position in session ENU (x: east, y: north, z: up relative to ear level).
    private(set) var ghostENU: SIMD3<Double> = .zero
    private var frameConfig = FrameConfig()

    // Near-field clamp state
    private var clampActive = false
    private var smoothedBearing: Double = 0
    private var lastTickTime: TimeInterval?

    private(set) var renderState = RenderState()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var isRunning: Bool { engine != nil }

    // MARK: Setup

    /// Builds the graph and starts the looping event. Tracking queue only.
    func start(ghost: Ghost, audioURL: URL, ghostENU: SIMD3<Double>, frameConfig: FrameConfig) throws {
        stop()

        self.ghostENU = ghostENU
        self.frameConfig = frameConfig
        self.smoothedBearing = atan2Bearing(east: ghostENU.x, north: ghostENU.y)
        self.clampActive = false
        self.lastTickTime = nil

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
        source.transform = Quat.transform(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                          position: Frames.phasePosition(ghostENU, cfg: frameConfig))
        try engine.rootObject.addChild(source)

        soundAssetID = "asset-\(ghost.id.uuidString)"
        eventAssetID = "event-\(ghost.id.uuidString)"

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
        mixerIdentifier = mixer.identifier          // needed to rebuild the event after a pause
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

        let params = PHASEMixerParameters()
        params.addSpatialMixerParameters(identifier: mixer.identifier, source: source, listener: listener)

        do {
            let event = try PHASESoundEvent(engine: engine, assetIdentifier: eventAssetID,
                                            mixerParameters: params)
            self.event = event
            event.start(completion: nil)
        } catch {
            throw SpatialAudioError.eventCreation(error.localizedDescription)
        }

        self.engine = engine
        self.listener = listener
        self.source = source
        renderState.isPlaying = true
        Log.info("SpatialAudioEngine started for ghost \(ghost.name)")
    }

    func stop() {
        event?.stopAndInvalidate()
        event = nil
        engine?.stop()
        if let engine {
            if !soundAssetID.isEmpty { engine.assetRegistry.unregisterAsset(identifier: soundAssetID, completion: nil) }
            if !eventAssetID.isEmpty { engine.assetRegistry.unregisterAsset(identifier: eventAssetID, completion: nil) }
        }
        listener = nil
        source = nil
        engine = nil
        renderState.isPlaying = false
    }

    /// Pause: stop the event but keep the engine and registered assets, so resuming is cheap
    /// (interruptions, AirPods out, non-headphone route — spec §7.1, §6.7).
    func pauseEvent() {
        event?.stopAndInvalidate()
        event = nil
        renderState.isPlaying = false
    }

    /// Recreates and restarts the event after a pause. Returns false if the graph is gone entirely.
    @discardableResult
    func resumeEvent() -> Bool {
        guard let engine, let source, let listener, event == nil, !eventAssetID.isEmpty else {
            return event != nil
        }
        // An interruption can leave the engine itself stopped once the audio session is torn
        // down and reactivated, so bring it back before rebuilding the event.
        if engine.renderingState != .started {
            do {
                try engine.start()
            } catch {
                Log.error("Failed to restart PHASE engine: \(error.localizedDescription)")
                return false
            }
        }
        // The mixer identifier is stored in the registered event asset, so rebuild parameters by
        // re-deriving it from the sound event asset's mixers.
        guard let mixerID = mixerIdentifier else { return false }
        let params = PHASEMixerParameters()
        params.addSpatialMixerParameters(identifier: mixerID, source: source, listener: listener)
        do {
            let event = try PHASESoundEvent(engine: engine, assetIdentifier: eventAssetID,
                                            mixerParameters: params)
            self.event = event
            event.start(completion: nil)
            renderState.isPlaying = true
            return true
        } catch {
            Log.error("Failed to resume sound event: \(error.localizedDescription)")
            return false
        }
    }

    private var mixerIdentifier: String?

    // MARK: Per-tick update

    /// Updates the listener transform and — inside the near-field clamp — the source transform.
    /// Tracking queue only.
    @discardableResult
    func updateListener(pose: ListenerPose, now: TimeInterval) -> RenderState {
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
        let rMin = max(Tuning.nearFieldFloor, pose.horizontalAccuracy)
        let enterClamp = r < rMin
        let exitClamp = r > rMin * Tuning.clampExitFactor
        if clampActive {
            if exitClamp { clampActive = false }
        } else if enterClamp {
            clampActive = true
        }

        var renderRel = rel
        if clampActive {
            smoothedBearing = lowpassAngle(current: smoothedBearing, target: trueBearing,
                                           tau: Tuning.nearFieldBearingTau, dt: dt)
            let dir = bearingToUnitENU(smoothedBearing)
            renderRel.x = rMin * dir.east
            renderRel.y = rMin * dir.north
            renderRel.z = rel.z                      // keep the true height
        } else {
            smoothedBearing = trueBearing
        }

        let listenerPhase = Frames.phasePosition(pose.enuPosition, cfg: frameConfig)
        listener?.transform = Quat.transform(rotation: pose.headOrientationPHASE, position: listenerPhase)

        // The source transform is static except in the clamp regime — the one documented exception.
        let sourceENU = clampActive ? (pose.enuPosition + renderRel) : ghostENU
        source?.transform = Quat.transform(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                           position: Frames.phasePosition(sourceENU, cfg: frameConfig))

        renderState.clampActive = clampActive
        renderState.trueDistance = simd_length(rel)
        renderState.renderedDistance = simd_length(renderRel)
        renderState.bearing = trueBearing
        renderState.renderedBearing = clampActive ? smoothedBearing : trueBearing
        renderState.elevation = rel.z
        return renderState
    }

    /// Called when the frame config changes from the Debug HUD (§15 sign flips).
    func setFrameConfig(_ cfg: FrameConfig) {
        frameConfig = cfg
    }

    /// Called when the ghost's rendered ENU position changes (origin re-seed, height edit).
    func setGhostENU(_ enu: SIMD3<Double>) {
        ghostENU = enu
    }
}
