import Foundation
import Observation
import simd

/// Throttled view of the tracking state for the UI (4 Hz — spec §3.3).
struct SessionSnapshot: Equatable {
    var enuPosition: SIMD3<Double> = .zero
    var horizontalAccuracy: Double = 0
    var fixAge: Double = 0
    var acceptedFixes = 0
    var rejectedFixes = 0
    var lastRejection = ""

    var attitudeYaw: Double = 0
    var yawOffset: Double = 0
    var trueYaw: Double = 0
    var pitch: Double = 0
    var course: Double = -1
    var courseError: Double?
    var calibrationQuality: CalibrationQuality = .none
    var calibrationAge: Double?

    var render = RenderState()
    var motionHz: Double = 0
    var motionAge: Double = 0
    var headphonesConnected = false
    var routeName = "—"

    /// Distance between the raw and smoothed positions — the τ tuning signal (§12).
    var rawSmoothedDelta: Double = 0
}

/// The app's beating heart (spec §8): owns the tracking queue, drives the state machine, fuses
/// pose on every headphone-motion callback, and keeps the UI fed with throttled snapshots.
///
/// Threading contract: `state`/`snapshot`/`needsCalibration` are only ever written on the main
/// queue, and so are the provider references. The rest of the mutable state lives on `trackingQueue`.
@Observable
final class SessionCoordinator {

    // MARK: Observable (main queue only)

    private(set) var state: SessionState = .idle
    private(set) var snapshot = SessionSnapshot()
    /// Set when the state machine asks for the calibration ritual.
    var needsCalibration = false
    private(set) var activeGhost: Ghost?

    // MARK: Collaborators

    @ObservationIgnored let logger = SessionLogger()
    @ObservationIgnored private let trackingQueue: DispatchQueue
    @ObservationIgnored private let calibration = CalibrationService()
    @ObservationIgnored private let audioEngine = SpatialAudioEngine()
    @ObservationIgnored private let audioSession = AudioSessionController()
    /// Whatever the location source is, its fixes come through here.
    @ObservationIgnored private let fixes = FixPipeline()
    @ObservationIgnored private let store: GhostStore
    @ObservationIgnored private let debug: DebugSettings
    @ObservationIgnored private let frames: FrameConfigStore
    /// Nil until the first session starts.
    @ObservationIgnored private var locationProvider: LocationProviding?
    @ObservationIgnored private var headProvider: HeadPoseProviding?

    // MARK: Main-queue state

    @ObservationIgnored private var audioURL: URL?
    @ObservationIgnored private var restartAttempted = false

    // MARK: Tracking-queue state

    /// Tracking-queue copy of the ghost, so the heartbeat never reads observable state.
    @ObservationIgnored private var trackingGhost: Ghost?
    /// Nil until the session's first accepted fix fixes the ENU origin.
    @ObservationIgnored private var ghostENU: SIMD3<Double>?
    @ObservationIgnored private var lastAttitudeYaw: Double = 0
    @ObservationIgnored private var lastSnapshotTime: TimeInterval = 0
    @ObservationIgnored private var poorAccuracySince: TimeInterval?
    @ObservationIgnored private var gpsDegraded = false
    @ObservationIgnored private var lastRejectionReason = ""

    init(store: GhostStore, debug: DebugSettings, frames: FrameConfigStore) {
        self.store = store
        self.debug = debug
        self.frames = frames
        self.trackingQueue = DispatchQueue(label: "com.audioghost.tracking", qos: .userInteractive)
        fixes.onFix = { [weak self] fix in self?.handle(fix) }
        fixes.onRejected = { [weak self] rejection in self?.lastRejectionReason = rejection.reason }
        wireAudioSession()
    }

    /// Location service, when it is the real one — used by the calibration ritual for headings.
    var headingProvider: HeadingProviding? { locationProvider as? HeadingProviding }

    // MARK: Public control

    func start(ghost: Ghost) {
        guard ghost.isPlayable, let url = store.audioURL(for: ghost) else {
            send(.ghostInvalid)
            return
        }
        activeGhost = ghost
        store.isLocked = true
        audioURL = url
        restartAttempted = false
        trackingQueue.async { [weak self] in
            guard let self else { return }
            self.trackingGhost = ghost
            self.ghostENU = nil
            self.fixes.reset()
            self.gpsDegraded = false
            self.poorAccuracySince = nil
        }
        send(.startRequested)
    }

    func stop() {
        send(.stopRequested)
        activeGhost = nil
    }

    func pauseByUser() { send(.userPaused) }
    func resumeByUser() { send(.userResumed) }

    /// Called by the calibration flow once the ritual succeeds.
    func applyCalibration(offset: Double) {
        calibration.applyPreciseOffset(offset)
        needsCalibration = false
        logger.event("calibration precise", state: "\(state)", quality: "precise")
        send(.calibrationBecameValid(.precise))
    }

    /// Current raw attitude yaw — the calibration flow samples this while the user holds still.
    var currentAttitudeYaw: Double {
        trackingQueue.sync { lastAttitudeYaw }
    }

    // MARK: State machine plumbing

    /// Feeds an event through the pure reducer and runs the resulting effects. Main queue.
    func send(_ event: SessionEvent) {
        if Thread.isMainThread {
            apply(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.apply(event) }
        }
    }

    private func apply(_ event: SessionEvent) {
        let (next, effects) = SessionReducer.reduce(state, event, calibration: calibration.quality)
        if next != state {
            Log.info("session: \(state) -[\(event)]-> \(next)")
            logger.event("state \(next)", state: "\(next)", quality: calibration.quality.rawValue)
            state = next
        }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: SessionEffect) {
        switch effect {
        case .startServices: startServices()
        case .stopServices: stopServices()
        case .startAudio: startAudio()
        case .pauseAudio: trackingQueue.async { [weak self] in self?.audioEngine.pauseEvent() }
        case .resumeAudio: resumeAudio()
        case .invalidateCalibration:
            calibration.invalidate()
            needsCalibration = true
        case .promptCalibration:
            needsCalibration = true
        }
    }

    // MARK: Effects

    private func startServices() {
        logger.start()

        do {
            try audioSession.activate()
        } catch {
            send(.audioEngineFailed(error.localizedDescription))
            return
        }

        // Location is started FIRST, before any gate that can bail out of this method. It is the
        // call that raises the location prompt, and iOS will not even list the app in Settings
        // until it has been asked once — so a user without AirPods must still get here.
        startLocation()

        // Head tracking — the heartbeat.
        let head: HeadPoseProviding = debug.useSyntheticHeadTracking
            ? SyntheticHeadPoseProvider(queue: trackingQueue, frameConfig: { [frames] in frames.config })
            : HeadTrackingService(queue: trackingQueue)
        headProvider = head
        head.onSample = { [weak self] sample in self?.handle(sample) }
        head.onConnectionChange = { [weak self] connected in
            self?.send(connected ? .airpodsReconnected : .airpodsDisconnected)
        }
        do {
            try head.start()
        } catch HeadTrackingError.permissionDenied {
            send(.motionPermissionDenied); return
        } catch {
            send(.headTrackingUnavailable); return
        }

        // Finally the route gate. It comes last on purpose: everything above either raises a
        // permission prompt or is needed regardless, and bailing out earlier is what left a user
        // without AirPods unable to grant anything at all.
        if !audioSession.isHeadphoneRoute && !debug.allowNonHeadphoneRoute {
            send(.headTrackingUnavailable)
        }
    }

    private func startLocation() {
        let location: LocationProviding
        if let path = debug.scriptedPath, let ghost = activeGhost {
            let scripted = ScriptedLocationProvider(ghost: ghost.coordinate, path: path,
                                                    queue: trackingQueue, pipeline: fixes)
            scripted.noiseSigma = debug.scriptedNoiseSigma
            scripted.reportedAccuracy = debug.scriptedReportedAccuracy
            location = scripted
        } else {
            location = LocationService(queue: trackingQueue, pipeline: fixes)
        }
        locationProvider = location
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // For a first-run user this suspends until they answer the system prompt, so the
                // session may already have failed (no AirPods) by the time it returns.
                try await location.start()
                if !self.state.isActive { location.stop() }
            } catch {
                self.send(.locationPermissionDenied)
            }
        }
    }

    private func stopServices() {
        headProvider?.stop()
        locationProvider?.stop()
        trackingQueue.async { [weak self] in self?.audioEngine.stop() }
        audioSession.deactivate()
        logger.stop()
        store.isLocked = false
        needsCalibration = false
    }

    private func startAudio() {
        guard let ghost = activeGhost, let url = audioURL else { return }
        let cfg = frames.config
        trackingQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.audioEngine.start(ghost: ghost, audioURL: url,
                                           ghostENU: self.ghostENU ?? .zero, frameConfig: cfg)
            } catch SpatialAudioError.assetLoad(let message) {
                self.send(.assetLoadFailed(message))
            } catch {
                self.send(.audioEngineFailed(error.localizedDescription))
            }
        }
    }

    private func resumeAudio() {
        trackingQueue.async { [weak self] in
            guard let self else { return }
            if !self.audioEngine.resumeEvent() {
                // The graph was torn down (or never built): rebuild it from scratch.
                DispatchQueue.main.async { self.startAudio() }
            }
        }
    }

    private func wireAudioSession() {
        audioSession.onInterruptionBegan = { [weak self] in self?.send(.audioInterrupted) }
        audioSession.onInterruptionEnded = { [weak self] resume in
            self?.send(.audioInterruptionEnded(shouldResume: resume))
        }
        audioSession.onRouteLeftHeadphones = { [weak self] in self?.send(.routeLeftHeadphones) }
        audioSession.onRouteReturnedToHeadphones = { [weak self] in
            self?.send(.routeReturnedToHeadphones)
        }
    }

    // MARK: Heartbeat (tracking queue)

    /// Every headphone-motion sample: fuse the pose, push it to PHASE, log, and (throttled) to UI.
    private func handle(_ sample: HeadSample) {
        let cfg = frames.config
        let now = AppClock.now
        let fix = fixes.latest

        let attitudeYaw = Frames.attitudeYaw(sample.attitude, cfg: cfg, fallback: lastAttitudeYaw)
        lastAttitudeYaw = attitudeYaw
        let yawOffset = calibration.yawOffset
        let rotation = Frames.listenerRotation(attitude: sample.attitude, yawOffset: yawOffset, cfg: cfg)

        let pose = ListenerPose(enuPosition: fix?.predictedENU(at: now) ?? .zero,
                                headOrientationPHASE: Quat.float(rotation),
                                horizontalAccuracy: fix?.horizontalAccuracy ?? 0,
                                motionTimestamp: sample.timestamp,
                                attitudeYaw: attitudeYaw,
                                trueYaw: wrapToPi(attitudeYaw + yawOffset),
                                pitch: Frames.attitudePitch(sample.attitude, cfg: cfg))

        let render = audioEngine.updateListener(pose: pose, now: now, frameConfig: cfg)

        checkGPSHealth(now: now, fix: fix)
        appendLogRow(now: now, pose: pose, fix: fix, render: render)
        publishSnapshotIfDue(now: now, pose: pose, fix: fix, render: render)
    }

    /// Every accepted fix: place the ghost on the first one, then run course-based drift correction.
    private func handle(_ fix: SmoothedFix) {
        let isStrongFix = fix.horizontalAccuracy <= Tuning.current.weakAccuracy
        if isStrongFix { poorAccuracySince = nil }

        if ghostENU == nil, let ghost = trackingGhost {
            let enu = ghost.enuPosition(origin: fix.origin)
            ghostENU = enu
            audioEngine.setGhostENU(enu)
            Log.info(String(format: "Origin seeded; ghost at E %.1f N %.1f U %.1f", enu.x, enu.y, enu.z))
        }

        if case .seededCoarse = calibration.updateWithCourse(fix: fix, attitudeYawNow: lastAttitudeYaw) {
            send(.calibrationBecameValid(.coarse))
        }

        // Recovery requires a *good* fix: a stream of weak ones is exactly what `.accuracyPoor`
        // is complaining about, so it must not clear itself.
        if gpsDegraded, isStrongFix {
            gpsDegraded = false
            send(.gpsRecovered)
        }
        send(.firstFixAccepted)     // no-ops in every state but `.acquiringFix`
    }

    /// Two distinct GPS complaints (§8.1), which must not be conflated:
    ///   * `.gpsLost`      — no accepted fix for `gpsStaleTimeout`; hold the last pose.
    ///   * `.accuracyPoor` — fixes are arriving, but they are consistently weak for
    ///                       `accuracyPoorTimeout`. This is the "GPS is weak here" case, and it
    ///                       is checked *before* the staleness threshold can mask it.
    private func checkGPSHealth(now: TimeInterval, fix: SmoothedFix?) {
        guard state.shouldPlayAudio || state == .awaitingCalibration, let fix else { return }

        if now - fix.timestamp > Tuning.current.gpsStaleTimeout {
            if !gpsDegraded {
                gpsDegraded = true
                send(.gpsWentStale)
            }
            return
        }

        if fix.horizontalAccuracy > Tuning.current.weakAccuracy {
            if poorAccuracySince == nil { poorAccuracySince = now }
            if let since = poorAccuracySince, now - since > Tuning.current.accuracyPoorTimeout, !gpsDegraded {
                gpsDegraded = true
                send(.gpsAccuracyPoor)
            }
        } else {
            poorAccuracySince = nil
        }
    }

    // MARK: Logging & snapshots

    private func appendLogRow(now: TimeInterval, pose: ListenerPose, fix: SmoothedFix?, render: RenderState) {
        guard logger.isRecording else { return }
        var r = LogRecord()
        r.state = "\(state)"
        if let fix {
            r.rawLat = fix.raw.coordinate.latitude
            r.rawLon = fix.raw.coordinate.longitude
            r.rawAcc = fix.horizontalAccuracy
            r.smoothedE = fix.smoothedENU.x
            r.smoothedN = fix.smoothedENU.y
            r.fixAge = now - fix.timestamp
            r.course = fix.raw.course
        }
        r.attYaw = pose.attitudeYaw
        r.yawOffset = calibration.yawOffset
        r.trueYaw = pose.trueYaw
        r.courseErr = calibration.lastCourseError ?? .nan
        r.calibQuality = calibration.quality.rawValue
        r.ghostDist = render.trueDistance
        r.ghostBearing = render.bearing
        r.clampActive = render.clampActive
        r.motionHz = headProvider?.measuredHz ?? 0
        logger.append(r)
    }

    private func publishSnapshotIfDue(now: TimeInterval, pose: ListenerPose, fix: SmoothedFix?, render: RenderState) {
        guard now - lastSnapshotTime >= 1 / max(1, Tuning.current.uiSnapshotHz) else { return }
        lastSnapshotTime = now

        var s = SessionSnapshot()
        s.enuPosition = pose.enuPosition
        s.horizontalAccuracy = pose.horizontalAccuracy
        s.fixAge = fix.map { now - $0.timestamp } ?? .infinity
        s.attitudeYaw = pose.attitudeYaw
        s.yawOffset = calibration.yawOffset
        s.trueYaw = pose.trueYaw
        s.pitch = pose.pitch
        s.courseError = calibration.lastCourseError
        s.calibrationQuality = calibration.quality
        s.calibrationAge = calibration.ageSeconds
        s.render = render
        s.motionHz = headProvider?.measuredHz ?? 0
        s.motionAge = now - pose.motionTimestamp
        s.headphonesConnected = headProvider?.isConnected ?? false
        s.rawSmoothedDelta = Geo.horizontalLength((fix?.rawENU ?? .zero) - pose.enuPosition)
        s.acceptedFixes = fixes.acceptedCount
        s.rejectedFixes = fixes.rejectedCount
        s.lastRejection = lastRejectionReason
        s.course = fix?.raw.course ?? -1

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            s.routeName = self.audioSession.currentRouteName
            self.snapshot = s
        }
    }

    // MARK: Staleness watchdog

    /// Called from the UI timer (1 Hz) — cheap, and the only place that can notice that the
    /// heartbeat itself has stopped (§6.7).
    func checkMotionStaleness() {
        guard state.shouldPlayAudio || state == .awaitingCalibration else { return }
        guard let service = headProvider as? HeadTrackingService, service.isConnected else { return }
        guard let last = service.lastSampleTime else { return }
        if AppClock.now - last > Tuning.current.motionStaleTimeout, !restartAttempted {
            restartAttempted = true
            Log.info("Motion stream stalled — restarting updates")
            logger.event("motion stalled; restarting")
            service.restart()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.restartAttempted = false
            }
        }
    }
}
