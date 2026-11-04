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
    var rotationRate: SIMD3<Double>
    /// Uptime seconds.
    var timestamp: TimeInterval
}

enum HeadTrackingError: LocalizedError {
    case unavailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This device can't read AirPods head motion. AudioGhost needs AirPods Pro, AirPods (3rd gen or later) or AirPods Max."
        case .permissionDenied:
            return "Motion access is required to track your head orientation."
        }
    }
}

/// Test seam (spec §3.2).
protocol HeadPoseProviding: AnyObject {
    var isConnected: Bool { get }
    var isAvailable: Bool { get }
    /// Called on the tracking queue.
    var onSample: ((HeadSample) -> Void)? { get set }
    /// Called on the main queue.
    var onConnectionChange: ((Bool) -> Void)? { get set }
    /// Measured sample rate, Hz (spec §3.3 marks the nominal ~25 Hz as [EMPIRICAL]).
    var measuredHz: Double { get }
    func start() throws
    func stop()
    /// Mounting correction slot (§6.5). Identity in MVP.
    var mountingCorrection: simd_quatd { get set }
}

/// `CMHeadphoneMotionManager` wrapper. The motion callback is the heartbeat of the whole app:
/// display-linked timers stop when backgrounded, motion callbacks do not (spec §3.3, spike S1).
final class HeadTrackingService: NSObject, HeadPoseProviding {

    var onSample: ((HeadSample) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var mountingCorrection: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    private let manager = CMHeadphoneMotionManager()
    private let queue: DispatchQueue
    private let operationQueue = OperationQueue()
    private let lock = NSLock()
    private var _isConnected = false
    private var _measuredHz: Double = 0
    private var lastTimestamp: TimeInterval?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    var measuredHz: Double {
        lock.lock(); defer { lock.unlock() }
        return _measuredHz
    }

    /// Uptime of the newest sample, or nil. Used for the §6.7 staleness check.
    var lastSampleTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastTimestamp
    }

    init(queue: DispatchQueue) {
        self.queue = queue
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
            guard let self else { return }
            if let error {
                Log.error("Headphone motion error: \(error.localizedDescription)")
                return
            }
            guard let motion else { return }
            self.handle(motion)
        }
        Log.info("HeadTrackingService started")
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock()
        lastTimestamp = nil
        _measuredHz = 0
        lock.unlock()
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

        lock.lock()
        if let last = lastTimestamp {
            let dt = motion.timestamp - last
            if dt > 0 {
                let instantaneous = 1 / dt
                _measuredHz = _measuredHz == 0 ? instantaneous : _measuredHz * 0.9 + instantaneous * 0.1
            }
        }
        lastTimestamp = motion.timestamp
        lock.unlock()

        let sample = HeadSample(
            attitude: corrected,
            rawAttitude: raw,
            gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
            rotationRate: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
            timestamp: motion.timestamp)
        onSample?(sample)
    }
}

extension HeadTrackingService: CMHeadphoneMotionManagerDelegate {

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        lock.lock(); _isConnected = true; lock.unlock()
        Log.info("AirPods connected")
        DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(true) }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lock.lock(); _isConnected = false; lastTimestamp = nil; lock.unlock()
        Log.info("AirPods disconnected")
        DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(false) }
    }
}

/// Desk/simulator stand-in: a head that slowly turns, so the whole pipeline (and the UI) can be
/// exercised without AirPods. Debug builds only — never offered in a release build.
final class SyntheticHeadPoseProvider: HeadPoseProviding {

    var onSample: ((HeadSample) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var mountingCorrection: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var isAvailable: Bool { true }
    private(set) var isConnected = false
    var measuredHz: Double { isConnected ? 25 : 0 }

    /// Head yaw sweep amplitude and period.
    var sweepAmplitude: Double = .pi
    var sweepPeriod: Double = 40

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
        let refUp = Frames.referenceUp(cfg)
        let refForward = SIMD3<Double>(cos(-yaw), sin(-yaw), 0)   // ccw = −compass
        let attitude = Quat.rotation(fromForward: cfg.headForwardLocal, fromUp: cfg.headUpLocal,
                                     toForward: refForward, toUp: refUp)
        let gravity = attitude.inverse.act(SIMD3<Double>(0, 0, -cfg.referenceUpSign))

        onSample?(HeadSample(attitude: (attitude * mountingCorrection).normalized,
                             rawAttitude: attitude,
                             gravity: gravity,
                             rotationRate: .zero,
                             timestamp: now))
    }
}
