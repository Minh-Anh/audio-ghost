import Foundation
import CoreMotion
import simd

struct HeadSample {
    /// Sensor-local → CoreMotion-reference rotation, after mounting correction (§6.5).
    var attitude: simd_quatd
    /// The same sample before mounting correction — FrameProbe works on this.
    var rawAttitude: simd_quatd
    /// Gravity in the *sensor* frame (points down). FrameProbe derives `headUpLocal` from it.
    var gravity: SIMD3<Double>
    /// Uptime seconds.
    var timestamp: TimeInterval
}

enum HeadTrackingError: Error {
    case unavailable
    case permissionDenied
}

/// Test seam (spec §3.2).
protocol HeadPoseProviding: AnyObject {
    var isConnected: Bool { get }
    /// Called on the tracking queue.
    var onSample: ((HeadSample) -> Void)? { get set }
    /// Called on the main queue.
    var onConnectionChange: ((Bool) -> Void)? { get set }
    /// Measured sample rate, Hz (spec §3.3 marks the nominal ~25 Hz as [EMPIRICAL]).
    var measuredHz: Double { get }
    func start() throws
    func stop()
}

/// `CMHeadphoneMotionManager` wrapper. The motion callback is the heartbeat of the whole app:
/// display-linked timers stop when backgrounded, motion callbacks do not (spec §3.3, spike S1).
final class HeadTrackingService: NSObject, HeadPoseProviding {

    var onSample: ((HeadSample) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// Mounting correction slot (§6.5). Identity in the MVP; nothing writes it yet.
    var mountingCorrection = simd_quatd.identityRotation

    private let manager = CMHeadphoneMotionManager()
    private let operationQueue = OperationQueue()
    private let lock = NSLock()
    private var connected = false
    private var hz: Double = 0
    private var lastTimestamp: TimeInterval?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isConnected: Bool { lock.withLock { connected } }
    var measuredHz: Double { lock.withLock { hz } }
    /// Uptime of the newest sample, or nil. Used for the §6.7 staleness check.
    var lastSampleTime: TimeInterval? { lock.withLock { lastTimestamp } }

    init(queue: DispatchQueue) {
        super.init()
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
        manager.delegate = self
    }

    func start() throws {
        guard manager.isDeviceMotionAvailable else { throw HeadTrackingError.unavailable }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted: throw HeadTrackingError.permissionDenied
        default: break
        }
        guard !manager.isDeviceMotionActive else { return }

        manager.startDeviceMotionUpdates(to: operationQueue) { [weak self] motion, error in
            if let error {
                Log.error("Headphone motion error: \(error.localizedDescription)")
                return
            }
            if let motion { self?.handle(motion) }
        }
        Log.info("HeadTrackingService started")
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.withLock {
            lastTimestamp = nil
            hz = 0
        }
    }

    /// Restart used to recover from a stalled stream (§6.7).
    func restart() {
        manager.stopDeviceMotionUpdates()
        try? start()
    }

    private func handle(_ motion: CMDeviceMotion) {
        let q = motion.attitude.quaternion
        let raw = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w).normalized
        // Mounting correction is applied on the right (sensor-local side): it is a fixed rotation
        // between "how the buds sit" and "where the head actually points".
        let corrected = (raw * mountingCorrection).normalized

        lock.withLock {
            if let last = lastTimestamp, motion.timestamp > last {
                let instantaneous = 1 / (motion.timestamp - last)
                hz = hz == 0 ? instantaneous : hz * 0.9 + instantaneous * 0.1
            }
            lastTimestamp = motion.timestamp
        }

        onSample?(HeadSample(attitude: corrected,
                             rawAttitude: raw,
                             gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
                             timestamp: motion.timestamp))
    }
}

extension HeadTrackingService: CMHeadphoneMotionManagerDelegate {

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        lock.withLock { connected = true }
        Log.info("AirPods connected")
        DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(true) }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lock.withLock {
            connected = false
            lastTimestamp = nil
        }
        Log.info("AirPods disconnected")
        DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(false) }
    }
}

/// Desk/simulator stand-in: a head that slowly turns, so the whole pipeline (and the UI) can be
/// exercised without AirPods. Debug builds only — never offered in a release build.
final class SyntheticHeadPoseProvider: HeadPoseProviding {

    var onSample: ((HeadSample) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var isConnected = false
    var measuredHz: Double { isConnected ? 25 : 0 }

    /// Head yaw sweep amplitude and period.
    private let sweepAmplitude: Double = .pi
    private let sweepPeriod: Double = 40

    private let queue: DispatchQueue
    private let frameConfig: () -> FrameConfig
    private var timer: DispatchSourceTimer?
    private var startTime: TimeInterval = 0

    init(queue: DispatchQueue, frameConfig: @escaping () -> FrameConfig) {
        self.queue = queue
        self.frameConfig = frameConfig
    }

    func start() throws {
        startTime = AppClock.now
        isConnected = true
        DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(true) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 25.0)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isConnected = false
    }

    private func tick() {
        let now = AppClock.now
        let t = now - startTime
        let cfg = frameConfig()

        // Synthesize an attitude for a level head whose nose sweeps in yaw. Built from the same
        // Frames constants as the real path, so a frame mistake shows up identically here.
        let yaw = sweepAmplitude * sin(2 * .pi * t / sweepPeriod)
        let refForward = SIMD3<Double>(cos(-yaw), sin(-yaw), 0)   // ccw = −compass
        let attitude = Quat.rotation(fromForward: cfg.headForwardLocal, fromUp: cfg.headUpLocal,
                                     toForward: refForward, toUp: Frames.referenceUp(cfg))
        let gravity = attitude.inverse.act(SIMD3<Double>(0, 0, -cfg.referenceUpSign))

        onSample?(HeadSample(attitude: attitude, rawAttitude: attitude, gravity: gravity, timestamp: now))
    }
}
