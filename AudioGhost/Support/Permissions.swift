import Foundation
import CoreLocation
import CoreMotion
import Observation
import UIKit

/// Proactive permission / hardware status for the Home footer (spec §9.1).
struct PermissionStatus: Equatable {
    var location: LocationAuthorization
    var motion: CMAuthorizationStatus
    var headTrackingAvailable: Bool

    var locationLabel: String {
        switch location {
        case .authorized: return "Location ready"
        case .notDetermined: return "Location access not requested yet"
        case .denied: return "Location denied — enable it in Settings"
        case .restricted: return "Location restricted on this device"
        }
    }

    var motionLabel: String {
        switch motion {
        case .authorized:
            return headTrackingAvailable ? "Head tracking ready" : "Motion allowed — connect your AirPods"
        case .denied:
            return "Motion denied — enable it in Settings"
        case .restricted:
            return "Motion restricted on this device"
        default:
            return headTrackingAvailable
                ? "Motion access not requested yet"
                : "Connect head-tracking AirPods to continue"
        }
    }

    var locationOK: Bool { location == .authorized }
    var motionOK: Bool { motion == .authorized && headTrackingAvailable }
    var isReady: Bool { locationOK && motionOK }

    /// True when tapping the row can actually produce a system prompt. iOS only lists an app in
    /// Settings once it has requested a permission, so "Open Settings" is useless before that.
    var canRequestLocation: Bool { location == .notDetermined }
    var canRequestMotion: Bool { motion == .notDetermined && headTrackingAvailable }
}

enum Permissions {

    static func status() -> PermissionStatus {
        let manager = CLLocationManager()
        let location: LocationAuthorization
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: location = .authorized
        case .denied: location = .denied
        case .restricted: location = .restricted
        default: location = .notDetermined
        }
        return PermissionStatus(location: location,
                                motion: CMHeadphoneMotionManager.authorizationStatus(),
                                headTrackingAvailable: CMHeadphoneMotionManager().isDeviceMotionAvailable)
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Asks for the two permissions the app needs, from the Home screen, before a session is started.
///
/// This exists because neither permission can be granted from iOS Settings until the app has
/// requested it once — and the only APIs that raise the prompts are
/// `requestWhenInUseAuthorization()` and `startDeviceMotionUpdates(to:withHandler:)`. Both
/// managers must stay alive for the callbacks, hence a retained object rather than free functions.
@Observable
final class PermissionCoordinator: NSObject, CLLocationManagerDelegate {

    private(set) var status: PermissionStatus = Permissions.status()
    private(set) var isRequestingMotion = false

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let headphoneManager = CMHeadphoneMotionManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func refresh() {
        status = Permissions.status()
    }

    func requestLocation() {
        guard status.location == .notDetermined else {
            Permissions.openSettings()
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }

    /// Raises the motion prompt by briefly starting headphone-motion updates. Requires compatible
    /// AirPods to be connected — `isDeviceMotionAvailable` is false otherwise and iOS will never
    /// ask, which is why the UI tells the user to connect them first.
    func requestMotion() {
        guard status.motion == .notDetermined else {
            Permissions.openSettings()
            return
        }
        guard headphoneManager.isDeviceMotionAvailable, !isRequestingMotion else { return }
        isRequestingMotion = true
        headphoneManager.startDeviceMotionUpdates(to: .main) { [weak self] _, _ in
            self?.finishMotionRequest()
        }
        // The handler never fires if the user declines, so stop on a timer regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finishMotionRequest()
        }
    }

    private func finishMotionRequest() {
        guard isRequestingMotion else { return }
        isRequestingMotion = false
        headphoneManager.stopDeviceMotionUpdates()
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }
}
