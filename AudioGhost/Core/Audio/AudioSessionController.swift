import Foundation
import AVFAudio

/// AVAudioSession lifecycle, interruptions and route changes (spec §7.1).
///
/// The active `.playback` session is what keeps the app alive in the background — and with it the
/// headphone-motion callbacks that are the app's heartbeat.
final class AudioSessionController {

    /// Main queue.
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?      // shouldResume
    var onRouteLeftHeadphones: (() -> Void)?
    var onRouteReturnedToHeadphones: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var wasHeadphones = false

    static let headphonePortTypes: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .usbAudio
    ]

    var isHeadphoneRoute: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.allSatisfy { Self.headphonePortTypes.contains($0.portType) }
    }

    var currentRouteName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "None"
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        wasHeadphones = isHeadphoneRoute
        subscribe()
    }

    func deactivate() {
        unsubscribe()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func subscribe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.onInterruptionBegan?()
                case .ended:
                    let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    // Re-activating the session is our job; PHASE will not do it for us.
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.onInterruptionEnded?(options.contains(.shouldResume))
                @unknown default:
                    break
                }
            })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
                guard let self else { return }
                let now = self.isHeadphoneRoute
                defer { self.wasHeadphones = now }
                guard now != self.wasHeadphones else { return }
                if now {
                    self.onRouteReturnedToHeadphones?()
                } else {
                    // Spatial audio through a phone speaker is meaningless and loud.
                    self.onRouteLeftHeadphones?()
                }
            })
    }

    private func unsubscribe() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit { unsubscribe() }
}
