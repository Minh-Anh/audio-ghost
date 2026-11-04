import Foundation
import CoreLocation
import simd

enum LocationAuthorization: Equatable {
    case notDetermined, denied, restricted, authorized

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        default: self = .notDetermined
        }
    }
}

enum LocationError: Error {
    case permissionDenied
}

/// Test seam (spec §3.2): anything that pushes raw fixes into the `FixPipeline` it was given.
/// `LocationService`, `ScriptedLocationProvider` and `ReplayLocationProvider` all conform.
protocol LocationProviding: AnyObject {
    func start() async throws
    func stop()
}

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

/// Heading is a separate seam because it is only ever used inside the calibration ritual —
/// a pocketed compass is garbage and `startUpdatingHeading` is power-hungry (spec §6.3).
protocol HeadingProviding: AnyObject {
    /// Delivered on the main queue.
    var onHeading: ((HeadingSample) -> Void)? { get set }
    /// False on a device with no magnetometer — the ritual is impossible and must say so.
    var isHeadingAvailable: Bool { get }
    func startHeading()
    func stopHeading()
}

/// CoreLocation wrapper: permissions, background updates, and the hop onto the tracking queue.
final class LocationService: NSObject, LocationProviding, HeadingProviding {

    var onHeading: ((HeadingSample) -> Void)?

    private let manager = CLLocationManager()
    private let queue: DispatchQueue
    private let pipeline: FixPipeline
    private var authContinuation: CheckedContinuation<Void, Error>?

    private var authorization: LocationAuthorization {
        LocationAuthorization(manager.authorizationStatus)
    }

    init(queue: DispatchQueue, pipeline: FixPipeline = FixPipeline()) {
        self.queue = queue
        self.pipeline = pipeline
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: Lifecycle

    func start() async throws {
        switch authorization {
        case .denied, .restricted:
            throw LocationError.permissionDenied
        case .notDetermined:
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                authContinuation = c
                manager.requestWhenInUseAuthorization()
            }
        case .authorized:
            break
        }
        guard authorization == .authorized else { throw LocationError.permissionDenied }

        // Only legal once authorized; requires the `location` background mode (Info.plist).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        Log.info("LocationService started")
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: Heading (calibration ritual only)

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
        if authorization == .authorized {
            c.resume()
        } else {
            c.resume(throwing: LocationError.permissionDenied)
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
        queue.async { [pipeline] in pipeline.ingest(fix) }
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
