import SwiftUI

/// The screen you glance at once and then pocket (spec §9.4).
struct SessionScreenView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var showCalibration = false
    @State private var showHUD = false
    @State private var watchdog: Timer?

    private var session: SessionCoordinator { app.session }

    var body: some View {
        VStack(spacing: 20) {
            header

            if let banner = session.state.banner {
                BannerView(text: banner, tone: tone(for: session.state))
            }

            distanceReadout

            chips

            Spacer(minLength: 0)

            if DebugSettings.isDebugBuild {
                DisclosureGroup("Debug HUD", isExpanded: $showHUD) {
                    DebugHUDView()
                }
                .font(.footnote)
            }

            controls
        }
        .padding(20)
        .sheet(isPresented: $showCalibration) {
            CalibrationFlowView()
        }
        .onChange(of: session.needsCalibration) { _, needs in
            if needs { showCalibration = true }
        }
        .onAppear {
            if session.needsCalibration { showCalibration = true }
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                session.checkMotionStaleness()
            }
        }
        .onDisappear {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text(session.activeGhost?.name ?? "Session")
                .font(.title2.bold())
            Spacer()
            Text(stateLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(tone(for: session.state).opacity(0.18)))
                .foregroundStyle(tone(for: session.state))
        }
    }

    private var distanceReadout: some View {
        let render = session.snapshot.render
        return VStack(spacing: 6) {
            Text(render.trueDistance > 0
                 ? String(format: "%.0f m %@", render.trueDistance, compassLabel(bearingRadians: render.bearing))
                 : "—")
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(render.clampActive ? "Very close — holding the sound steady"
                                    : "to the ghost")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HeadingDial(relativeBearing: wrapToPi(render.bearing - session.snapshot.trueYaw))
                .frame(width: 140, height: 140)
                .padding(.top, 8)
        }
    }

    private var chips: some View {
        let s = session.snapshot
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Chip(icon: "location.fill",
                     text: s.horizontalAccuracy > 0 ? "±\(Int(s.horizontalAccuracy)) m" : "no fix",
                     ok: s.horizontalAccuracy > 0 && s.horizontalAccuracy <= 15)
                Chip(icon: "airpodspro",
                     text: s.headphonesConnected ? "AirPods" : "no AirPods",
                     ok: s.headphonesConnected)
                Chip(icon: "dot.radiowaves.left.and.right",
                     text: String(format: "%.0f Hz", s.motionHz),
                     ok: s.motionHz > 10)
            }
            HStack(spacing: 10) {
                Chip(icon: "safari",
                     text: s.calibrationQuality.label + (s.calibrationAge.map { String(format: " · %.0f min", $0 / 60) } ?? ""),
                     ok: s.calibrationQuality != .none)
                Button {
                    showCalibration = true
                } label: {
                    Label("Recalibrate", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if case .paused(let reason) = session.state, reason == .userPaused {
                Button {
                    session.resumeByUser()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if session.state.shouldPlayAudio {
                Button {
                    session.pauseByUser()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                session.stop()
                dismiss()
            } label: {
                Text("Stop session")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle: return "Idle"
        case .acquiringFix: return "Finding you"
        case .awaitingCalibration: return "Uncalibrated"
        case .running(let q): return q == .precise ? "Running" : "Running (coarse)"
        case .degraded: return "Degraded"
        case .paused: return "Paused"
        case .failed: return "Failed"
        }
    }

    private func tone(for state: SessionState) -> Color {
        switch state {
        case .running(let q): return q == .precise ? .green : .teal
        case .degraded: return .orange
        case .paused: return .yellow
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct BannerView: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(tone.opacity(0.15)))
            .foregroundStyle(tone)
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    let ok: Bool

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.15)))
            .foregroundStyle(ok ? .green : .orange)
    }
}

/// Where the ghost is relative to your nose. Up = straight ahead.
private struct HeadingDial: View {
    let relativeBearing: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1, height: 10)
                    .offset(y: -62)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .offset(y: -44)
                .rotationEffect(.radians(relativeBearing))
                .animation(.easeOut(duration: 0.12), value: relativeBearing)
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
