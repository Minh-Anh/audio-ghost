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
///
/// Thread-safe: the tracking queue applies course updates and the main queue applies the ritual.
final class CalibrationService {

    /// Minimum samples of each kind the ritual solver needs.
    static let minimumRitualSamples = 5

    private let lock = NSLock()
    private var offset: Double = 0
    private var currentQuality: CalibrationQuality = .none
    private var calibratedAt: TimeInterval?
    private var courseError: Double?
    private var courseDistanceWalked: Double = 0
    private var lastCourseFixENU: SIMD3<Double>?

    /// The offset to render with. Stays at its last value when invalidated and is 0 before the
    /// first calibration: audio still plays, just unaligned. Check `isValid` before trusting it.
    var yawOffset: Double { lock.withLock { offset } }

    var quality: CalibrationQuality { lock.withLock { currentQuality } }

    var isValid: Bool { quality != .none }

    var ageSeconds: Double? {
        lock.withLock { calibratedAt.map { AppClock.now - $0 } }
    }

    /// Most recent course-vs-head disagreement, radians. The HUD's tuning signal for `courseGain`.
    var lastCourseError: Double? { lock.withLock { courseError } }

    /// True when the latest course error suggests the user should redo the ritual.
    var suggestsRecalibration: Bool {
        guard let e = lastCourseError else { return false }
        return abs(e) > Tuning.current.recalibrateHintError
    }

    // MARK: Invalidation

    /// Called on AirPods disconnect: the reference frame resets, so the offset means nothing.
    func invalidate() {
        lock.withLock {
            currentQuality = .none
            calibratedAt = nil
            courseError = nil
            courseDistanceWalked = 0
            lastCourseFixENU = nil
        }
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
        guard headings.count >= minimumRitualSamples, attitudeYaws.count >= minimumRitualSamples else {
            return .failure(.notEnoughSamples)
        }
        if headingAccuracies.contains(where: { $0 < 0 }) { return .failure(.compassNeedsCalibration) }
        if let worst = headingAccuracies.max(), worst > Tuning.current.calibrationMaxHeadingAccuracy {
            return .failure(.compassInaccurate(worst))
        }
        let headingSpread = circularSpread(headings)
        let attitudeSpread = circularSpread(attitudeYaws)
        guard headingSpread <= Tuning.current.calibrationMaxHeadingSpread,
              attitudeSpread <= Tuning.current.calibrationMaxAttitudeSpread else {
            return .failure(.userMoved(headingSpread: headingSpread, attitudeSpread: attitudeSpread))
        }
        guard let headingMean = circularMean(headings),
              let attitudeMean = circularMean(attitudeYaws) else {
            return .failure(.notEnoughSamples)
        }
        return .success(wrapToPi(headingMean - attitudeMean))
    }

    /// Commits a solved ritual offset.
    func applyPreciseOffset(_ newOffset: Double) {
        lock.withLock {
            offset = wrapToPi(newOffset)
            currentQuality = .precise
            calibratedAt = AppClock.now
            courseError = nil
        }
        Log.info(String(format: "Calibrated (precise): yawOffset = %.1f°", newOffset.degrees))
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
        let tuning = Tuning.current
        let update: CourseUpdate = lock.withLock {
            guard fix.raw.speed > tuning.courseMinSpeed else {
                lastCourseFixENU = nil
                return .ignoredSlow
            }
            guard let course = fix.raw.courseRadians,
                  fix.raw.courseAccuracy >= 0,
                  fix.raw.courseAccuracy < tuning.maxCourseAccuracy else {
                return .ignoredCourseAccuracy
            }

            // Track distance walked with a usable course, for the cold-start seed.
            if let last = lastCourseFixENU {
                courseDistanceWalked += Geo.horizontalLength(fix.smoothedENU - last)
            }
            lastCourseFixENU = fix.smoothedENU

            if currentQuality == .none {
                guard courseDistanceWalked >= tuning.coarseSeedDistance else {
                    return .accumulating(courseDistanceWalked)
                }
                offset = wrapToPi(course - attitudeYawNow)
                currentQuality = .coarse
                calibratedAt = AppClock.now
                courseError = 0
                return .seededCoarse(offset)
            }

            let error = wrapToPi(course - wrapToPi(attitudeYawNow + offset))
            courseError = error
            guard abs(error) < tuning.courseGateAngle else {
                return .ignoredHeadTurned(error)    // head turned while walking: don't corrupt the offset
            }
            offset = wrapToPi(offset + tuning.courseGain * error)
            return .corrected(error)
        }
        if case .seededCoarse(let seeded) = update {
            Log.info(String(format: "Calibrated (coarse, course seed): yawOffset = %.1f°", seeded.degrees))
        }
        return update
    }
}
