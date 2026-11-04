import Foundation
import simd

enum CalibrationQuality: String, Codable, Equatable {
    case none, coarse, precise

    var label: String {
        switch self {
        case .none: return "Not calibrated"
        case .coarse: return "Coarse"
        case .precise: return "Precise"
        }
    }
}

enum CalibrationError: LocalizedError, Equatable {
    case notEnoughSamples
    case compassUnavailable
    case trueNorthUnavailable             // CLHeading.trueHeading == −1 (no location fix yet)
    case compassNeedsCalibration          // iOS reported headingAccuracy < 0
    case compassInaccurate(Double)        // worse than the gate
    case userMoved(headingSpread: Double, attitudeSpread: Double)

    var errorDescription: String? {
        switch self {
        case .notEnoughSamples:
            return "The compass didn't report often enough to get a reading. Try again — and if it keeps failing, use walking calibration instead."
        case .compassUnavailable:
            return "This device has no compass, so the guided calibration can't run. Walk about 15 m and AudioGhost will calibrate itself from your direction of travel."
        case .trueNorthUnavailable:
            return "The compass can't find true north until there's a GPS fix. Step outside, wait for the accuracy chip to settle, then try again."
        case .compassNeedsCalibration:
            return "The compass needs calibrating. Wave the phone in a figure 8, then try again."
        case .compassInaccurate(let a):
            return String(format: "The compass is only accurate to ±%.0f° here. Move away from metal and try again.", a)
        case .userMoved(let h, let att):
            return String(format: "You moved during the measurement (%.0f° / %.0f°). Stand still and try again.",
                          h.degrees, att.degrees)
        }
    }
}

/// Owner of `yawOffset` — the single most important scalar in the app (spec §6.2–6.4).
///
/// `trueYaw = wrapToPi(attitudeYaw + yawOffset)`. The offset is invalid until first calibration
/// and is invalidated on AirPods reconnect (the CoreMotion reference frame's horizontal axes are
/// re-randomised). Two ways to (re)acquire it: the compass ritual (precise) and GPS course
/// (coarse, hands-free, also used as slow drift correction while walking).
final class CalibrationService {

    // MARK: Observable-ish state (guarded)

    private let lock = NSLock()
    private var _yawOffset: Double = 0
    private var _quality: CalibrationQuality = .none
    private var _calibratedAt: TimeInterval?
    private var _lastCourseError: Double?
    private var _courseDistanceWalked: Double = 0
    private var _lastCourseFixENU: SIMD3<Double>?

    var yawOffset: Double? {
        lock.lock(); defer { lock.unlock() }
        return _quality == .none ? nil : _yawOffset
    }

    /// Offset to apply for rendering: 0 while uncalibrated (audio still plays, just unaligned).
    var renderingYawOffset: Double {
        lock.lock(); defer { lock.unlock() }
        return _yawOffset
    }

    var quality: CalibrationQuality {
        lock.lock(); defer { lock.unlock() }
        return _quality
    }

    var isValid: Bool { quality != .none }

    var calibratedAt: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return _calibratedAt
    }

    var ageSeconds: Double? {
        guard let at = calibratedAt else { return nil }
        return AppClock.now - at
    }

    /// Most recent course-vs-head disagreement, radians. The HUD's tuning signal for `courseGain`.
    var lastCourseError: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastCourseError
    }

    /// True when sustained course error suggests the user should redo the ritual.
    var suggestsRecalibration: Bool {
        guard let e = lastCourseError else { return false }
        return abs(e) > Tuning.recalibrateHintError
    }

    // MARK: Invalidation

    /// Called on AirPods reconnect: the reference frame reset, so the offset means nothing.
    func invalidate() {
        lock.lock()
        _quality = .none
        _calibratedAt = nil
        _lastCourseError = nil
        _courseDistanceWalked = 0
        _lastCourseFixENU = nil
        lock.unlock()
        Log.info("Calibration invalidated")
    }

    // MARK: Ritual (§6.3)

    /// Pure solver for the compass ritual, separated from the UI that collects the samples so it
    /// can be unit-tested against the §6.3 gates.
    ///
    /// - Parameters:
    ///   - headings: true headings, radians cw from north.
    ///   - headingAccuracies: degrees, as CoreLocation reports them (negative = needs figure-8).
    ///   - attitudeYaws: `Frames.attitudeYaw` values sampled over the same window.
    static func solveRitual(headings: [Double],
                            headingAccuracies: [Double],
                            attitudeYaws: [Double]) -> Result<Double, CalibrationError> {
        guard headings.count >= 5, attitudeYaws.count >= 5 else { return .failure(.notEnoughSamples) }
        if headingAccuracies.contains(where: { $0 < 0 }) { return .failure(.compassNeedsCalibration) }
        if let worst = headingAccuracies.max(), worst > Tuning.calibrationMaxHeadingAccuracy {
            return .failure(.compassInaccurate(worst))
        }
        let headingSpread = circularSpread(headings)
        let attitudeSpread = circularSpread(attitudeYaws)
        guard headingSpread <= Tuning.calibrationMaxHeadingSpread,
              attitudeSpread <= Tuning.calibrationMaxAttitudeSpread else {
            return .failure(.userMoved(headingSpread: headingSpread, attitudeSpread: attitudeSpread))
        }
        guard let headingMean = circularMean(headings),
              let attitudeMean = circularMean(attitudeYaws) else {
            return .failure(.notEnoughSamples)
        }
        return .success(wrapToPi(headingMean - attitudeMean))
    }

    /// Commits a solved ritual offset.
    func applyPreciseOffset(_ offset: Double) {
        lock.lock()
        _yawOffset = wrapToPi(offset)
        _quality = .precise
        _calibratedAt = AppClock.now
        _lastCourseError = nil
        lock.unlock()
        Log.info(String(format: "Calibrated (precise): yawOffset = %.1f°", offset.degrees))
    }

    // MARK: Course-based drift correction & cold start (§6.4)

    enum CourseUpdate: Equatable {
        case ignoredSlow
        case ignoredCourseAccuracy
        case ignoredHeadTurned(Double)   // error, radians
        case corrected(Double)           // error, radians
        case seededCoarse(Double)        // offset, radians
        case accumulating(Double)        // meters walked so far toward the coarse seed
    }

    /// Call on every accepted fix, on the tracking queue.
    /// - Parameter attitudeYawNow: the current raw `Frames.attitudeYaw` value.
    @discardableResult
    func updateWithCourse(fix: SmoothedFix, attitudeYawNow: Double) -> CourseUpdate {
        guard fix.raw.speed > Tuning.courseMinSpeed else {
            lock.lock(); _lastCourseFixENU = nil; lock.unlock()
            return .ignoredSlow
        }
        guard let course = fix.raw.courseRadians,
              fix.raw.courseAccuracy >= 0,
              fix.raw.courseAccuracy < Tuning.maxCourseAccuracy else {
            return .ignoredCourseAccuracy
        }

        lock.lock()
        // Track distance walked with a usable course, for the cold-start seed.
        if let last = _lastCourseFixENU {
            _courseDistanceWalked += Geo.horizontalLength(fix.smoothedENU - last)
        }
        _lastCourseFixENU = fix.smoothedENU

        if _quality == .none {
            guard _courseDistanceWalked >= Tuning.coarseSeedDistance else {
                let walked = _courseDistanceWalked
                lock.unlock()
                return .accumulating(walked)
            }
            _yawOffset = wrapToPi(course - attitudeYawNow)
            _quality = .coarse
            _calibratedAt = AppClock.now
            _lastCourseError = 0
            let seeded = _yawOffset
            lock.unlock()
            Log.info(String(format: "Calibrated (coarse, course seed): yawOffset = %.1f°", seeded.degrees))
            return .seededCoarse(seeded)
        }

        let trueYaw = wrapToPi(attitudeYawNow + _yawOffset)
        let err = wrapToPi(course - trueYaw)
        _lastCourseError = err
        guard abs(err) < Tuning.courseGateAngle else {
            lock.unlock()
            return .ignoredHeadTurned(err)      // head turned while walking: don't corrupt the offset
        }
        _yawOffset = wrapToPi(_yawOffset + Tuning.courseGain * err)
        lock.unlock()
        return .corrected(err)
    }

    /// True yaw for a raw attitude yaw, using the current offset.
    func trueYaw(attitudeYaw: Double) -> Double {
        wrapToPi(attitudeYaw + renderingYawOffset)
    }
}
