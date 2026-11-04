import Foundation
import CoreLocation
import simd

enum LocationAuthorization: Equatable {
    case notDetermined, denied, restricted, authorized
}

enum LocationError: LocalizedError {
    case permissionDenied
    case servicesDisabled

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Location permission is required to place sounds in the world."
        case .servicesDisabled: return "Location Services are turned off."
        }
    }
}

/// Test seam (spec §3.2). `ScriptedLocationProvider` and `ReplayLocationProvider` conform too.
protocol LocationProviding: AnyObject {
    /// Thread-safe snapshot of the newest accepted, smoothed fix.
    var latest: SmoothedFix? { get }
    /// Delivered on the tracking queue.
    var onFix: ((SmoothedFix) -> Void)? { get set }
    /// Delivered on the main queue; raw fixes that were rejected, for HUD starvation stats.
    var onRejectedFix: ((RawFix, String) -> Void)? { get set }
    var authorization: LocationAuthorization { get }
    func start() async throws
    func stop()
    /// Forgets the ENU origin and filter state; the next accepted fix seeds a new origin.
    func resetOrigin()
}

/// Heading is a separate seam because it is only ever used inside the calibration ritual —
/// a pocketed compass is garbage and `startUpdatingHeading` is power-hungry (spec §6.3).
/// One compass reading, as the calibration ritual sees it.
struct HeadingSample: Equatable {
    /// Radians clockwise from TRUE north. Meaningless unless `isTrueHeadingValid`.
    var trueHeadingRadians: Double
    /// Degrees. Negative means iOS wants the figure-8 calibration gesture.
    var accuracyDegrees: Double
    /// `CLHeading.trueHeading` is only valid while location updates are running — it needs the
    /// magnetic declination for the current location. Without it CoreLocation reports −1, and
    /// calibrating against that would silently produce a wrong `yawOffset`.
    var isTrueHeadingValid: Bool
}

protocol HeadingProviding: AnyObject {
    var onHeading: ((HeadingSample) -> Void)? { get set }
    /// False on a device with no magnetometer — the ritual is impossible and must say so.
    var isHeadingAvailable: Bool { get }
    func startHeading()
    func stopHeading()
}

/// CoreLocation wrapper: permissions, background updates, outlier rejection, smoothing (§5.3).
final class LocationService: NSObject, LocationProviding, HeadingProviding {

    // MARK: Seams

    var onFix: ((SmoothedFix) -> Void)?
    var onRejectedFix: ((RawFix, String) -> Void)?
    var onHeading: ((HeadingSample) -> Void)?

    // MARK: State

    private let manager = CLLocationManager()
    private let queue: DispatchQueue
    private let pipeline: FixPipeline
    private var authContinuation: CheckedContinuation<Void, Error>?
    private var isRunning = false

    var rejectedCount: Int { pipeline.rejectedCount }
    var acceptedCount: Int { pipeline.acceptedCount }

    var latest: SmoothedFix? { pipeline.latest }

    var authorization: LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .notDetermined
        }
    }

    init(queue: DispatchQueue, pipeline: FixPipeline = FixPipeline()) {
        self.queue = queue
        self.pipeline = pipeline
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingOrientation = .portrait
    }

    // MARK: Lifecycle

    func start() async throws {
        switch authorization {
        case .denied: throw LocationError.permissionDenied
        case .restricted: throw LocationError.permissionDenied
        case .notDetermined:
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                authContinuation = c
                manager.requestWhenInUseAuthorization()
            }
        case .authorized: break
        }
        guard authorization == .authorized else { throw LocationError.permissionDenied }

        // Only legal once authorized; requires the `location` background mode (Info.plist).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        isRunning = true
        manager.startUpdatingLocation()
        Log.info("LocationService started")
    }

    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    func resetOrigin() {
        pipeline.reset()
    }

    /// Current session origin, if one has been seeded.
    var sessionOrigin: Geo.Coordinate? { pipeline.origin }

    // MARK: Heading (calibration ritual only)

    /// True when the device has a usable magnetometer.
    var isHeadingAvailable: Bool { CLLocationManager.headingAvailable() }

    /// Exposed for the regression test on `headingFilter` below.
    var headingFilter: CLLocationDegrees { manager.headingFilter }

    func startHeading() {
        manager.headingOrientation = .portrait
        // CRITICAL: the default headingFilter is 1°, so iOS only delivers an update once the
        // heading has *changed* by more than that. The calibration ritual asks the user to stand
        // perfectly still, which suppresses almost every update and starves the sample window —
        // the stiller they hold it, the fewer samples arrive. Take every update instead.
        manager.headingFilter = kCLHeadingFilterNone
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        manager.stopUpdatingHeading()
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let c = authContinuation, manager.authorizationStatus != .notDetermined else { return }
        authContinuation = nil
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: c.resume()
        default: c.resume(throwing: LocationError.permissionDenied)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = RawFix(coordinate: Geo.Coordinate(latitude: location.coordinate.latitude,
                                                   longitude: location.coordinate.longitude),
                         horizontalAccuracy: location.horizontalAccuracy,
                         speed: location.speed,
                         course: location.course,
                         courseAccuracy: location.courseAccuracy,
                         timestamp: AppClock.uptime(for: location.timestamp))
        queue.async { [weak self] in self?.ingest(fix) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let sample = HeadingSample(trueHeadingRadians: wrapToPi(newHeading.trueHeading.radians),
                                   accuracyDegrees: newHeading.headingAccuracy,
                                   isTrueHeadingValid: newHeading.trueHeading >= 0)
        DispatchQueue.main.async { [weak self] in self?.onHeading?(sample) }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        // The ritual UI explains the figure-8 itself; the system dialog on top of it is noise.
        false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.error("CoreLocation error: \(error.localizedDescription)")
    }
}

// MARK: - Ingestion (tracking queue)

extension LocationService {

    /// Runs on the tracking queue.
    func ingest(_ fix: RawFix) {
        switch pipeline.ingest(fix) {
        case .success(let smoothed):
            onFix?(smoothed)
        case .failure(let rejection):
            let reason = rejection.reason
            DispatchQueue.main.async { [weak self] in self?.onRejectedFix?(fix, reason) }
        }
    }
}
