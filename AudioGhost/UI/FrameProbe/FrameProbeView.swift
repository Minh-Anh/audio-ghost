import SwiftUI
import simd

/// The §6.1 FrameProbe: ten minutes of measurement that eliminates the entire class of
/// "which axis is forward" bugs.
///
/// Rather than only *displaying* numbers for a human to transcribe, this screen solves for the
/// sensor frame directly and writes it into `FrameConfig`:
///   * `headUpLocal`  = −(mean gravity) with the head level — gravity is unambiguous.
///   * `headRightLocal` = −(rotation axis of the "nod down" move), because a downward nod is a
///     negative rotation about the ear-to-ear axis under the right-hand rule.
///   * `headForwardLocal` = up × right.
///   * `referenceUpSign` = sign of the reference-frame z component of the level head's up vector.
/// The turn-right step is then used as an independent check that derived yaw increases clockwise.
struct FrameProbeView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = FrameProbeModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.isConnected {
                        Text("Put your AirPods in. If you're on the simulator, enable synthetic head tracking in Desk simulation — the probe will simply confirm the defaults.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    liveBlock

                    stepBlock

                    if let result = model.result {
                        resultBlock(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Frame probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { model.start(frames: app.frames) }
            .onDisappear { model.stop() }
        }
    }

    private var liveBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIVE").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(model.liveText)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var stepBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(FrameProbeModel.Step.allCases) { step in
                HStack(alignment: .top) {
                    Image(systemName: model.captured[step] != nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.captured[step] != nil ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(step.title).font(.subheadline.weight(.semibold))
                        Text(step.instruction).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.activeStep == step ? "\(model.countdown)…" : "Hold") {
                        model.capture(step)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.activeStep != nil)
                }
            }

            HStack {
                Button("Solve & save") { model.solveAndSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSolve)
                Button("Reset") { model.reset() }
            }
        }
    }

    private func resultBlock(_ result: FrameProbeModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RESULT").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(result.text)
                .font(.system(.caption, design: .monospaced))
            if let warning = result.warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

@Observable
final class FrameProbeModel {

    enum Step: String, CaseIterable, Identifiable {
        case level, turnRight, nodDown, rollRight
        var id: String { rawValue }

        var title: String {
            switch self {
            case .level: return "1 · Look straight ahead, level"
            case .turnRight: return "2 · Turn your head 90° right"
            case .nodDown: return "3 · Nod 45° down"
            case .rollRight: return "4 · Tilt head to right shoulder"
            }
        }

        var instruction: String {
            switch self {
            case .level: return "Gives the top-of-head axis from gravity."
            case .turnRight: return "Checks that derived yaw increases clockwise."
            case .nodDown: return "Gives the ear-to-ear axis from the rotation axis."
            case .rollRight: return "Cross-check: this axis should be the nose axis."
            }
        }
    }

    struct Capture {
        var attitude: simd_quatd
        var gravity: SIMD3<Double>
    }

    struct Result {
        var text: String
        var warning: String?
    }

    private(set) var captured: [Step: Capture] = [:]
    private(set) var activeStep: Step?
    private(set) var countdown = 3
    private(set) var liveText = "waiting for samples…"
    private(set) var result: Result?
    private(set) var isConnected = false

    private var provider: HeadPoseProviding?
    private var frames: FrameConfigStore?
    private let queue = DispatchQueue(label: "com.audioghost.frameprobe")
    private var collecting: [Capture] = []
    private var timer: Timer?
    private var latest: Capture?

    var canSolve: Bool { captured[.level] != nil && captured[.nodDown] != nil }

    func start(frames: FrameConfigStore) {
        self.frames = frames
        let service = HeadTrackingService(queue: queue)
        if service.isAvailable {
            provider = service
        } else {
            provider = SyntheticHeadPoseProvider(queue: queue, frameConfig: { frames.config })
        }
        provider?.onSample = { [weak self] sample in
            guard let self else { return }
            let capture = Capture(attitude: sample.rawAttitude, gravity: sample.gravity)
            DispatchQueue.main.async {
                self.latest = capture
                self.isConnected = true
                if self.activeStep != nil { self.collecting.append(capture) }
                self.updateLiveText(sample)
            }
        }
        try? provider?.start()
    }

    func stop() {
        provider?.stop()
        provider = nil
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        captured.removeAll()
        result = nil
    }

    /// Holds a pose for three seconds and stores the averaged sample.
    func capture(_ step: Step) {
        guard activeStep == nil else { return }
        activeStep = step
        countdown = 3
        collecting.removeAll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return }
            countdown -= 1
            if countdown <= 0 {
                t.invalidate()
                self.finishCapture(step)
            }
        }
    }

    private func finishCapture(_ step: Step) {
        activeStep = nil
        let samples = collecting.isEmpty ? [latest].compactMap { $0 } : collecting
        guard !samples.isEmpty else { return }
        captured[step] = Capture(attitude: Self.meanQuaternion(samples.map(\.attitude)),
                                 gravity: Self.meanVector(samples.map(\.gravity)))
    }

    private func updateLiveText(_ sample: HeadSample) {
        let q = sample.rawAttitude
        let cfg = frames?.config ?? FrameConfig()
        let yaw = Frames.attitudeYaw(q, cfg: cfg, fallback: 0)
        liveText = String(
            format: """
            q  w %+.3f  x %+.3f  y %+.3f  z %+.3f
            g  %+.3f %+.3f %+.3f   (sensor frame)
            q·x̂ %+.2f %+.2f %+.2f
            q·ŷ %+.2f %+.2f %+.2f
            q·ẑ %+.2f %+.2f %+.2f
            derived yaw %+.1f°   pitch %+.1f°
            """,
            q.real, q.imag.x, q.imag.y, q.imag.z,
            sample.gravity.x, sample.gravity.y, sample.gravity.z,
            q.act(SIMD3(1, 0, 0)).x, q.act(SIMD3(1, 0, 0)).y, q.act(SIMD3(1, 0, 0)).z,
            q.act(SIMD3(0, 1, 0)).x, q.act(SIMD3(0, 1, 0)).y, q.act(SIMD3(0, 1, 0)).z,
            q.act(SIMD3(0, 0, 1)).x, q.act(SIMD3(0, 0, 1)).y, q.act(SIMD3(0, 0, 1)).z,
            yaw.degrees, Frames.attitudePitch(q, cfg: cfg).degrees)
    }

    // MARK: The solve

    func solveAndSave() {
        guard let level = captured[.level], let nod = captured[.nodDown], let frames else { return }

        // Up: gravity points down in the sensor frame, so the top of the head is its negation.
        let up = simd_normalize(-level.gravity)

        // Right: a downward nod is a NEGATIVE rotation about the ear-to-ear axis (right-hand rule
        // with forward × up = right), so negate the measured axis.
        let deltaLocal = (level.attitude.inverse * nod.attitude).normalized
        guard var right = Quat.axis(of: deltaLocal) else {
            result = Result(text: "The nod step didn't move enough to find an axis.",
                            warning: "Redo step 3 with a clear 45° nod.")
            return
        }
        right = -right
        // Orthogonalize against up, then forward = up × right.
        right = simd_normalize(right - up * simd_dot(right, up))
        let forward = simd_normalize(simd_cross(up, right))

        // Reference vertical sign: with a level head, the top of the head must map onto the
        // reference frame's vertical.
        let upInReference = level.attitude.act(up)
        let referenceUpSign: Double = upInReference.z >= 0 ? 1 : -1

        var cfg = frames.observed
        cfg.headForwardLocal = forward
        cfg.headUpLocal = up
        cfg.referenceUpSign = referenceUpSign
        cfg.probedAt = Date()

        // Independent check: turning the head right must increase the compass-convention yaw.
        var warning: String?
        var turnText = "turn-right step not captured"
        if let turn = captured[.turnRight] {
            let before = Frames.attitudeYaw(level.attitude, cfg: cfg, fallback: 0)
            let after = Frames.attitudeYaw(turn.attitude, cfg: cfg, fallback: 0)
            let delta = wrapToPi(after - before)
            turnText = String(format: "turn-right Δyaw %+.0f° (expect ≈ +90°)", delta.degrees)
            if delta < 0 {
                warning = "Turning right DECREASED the derived yaw. The derived frame is mirrored — recheck that step 3 was a downward nod (not upward) and redo."
            } else if abs(delta.degrees - 90) > 35 {
                warning = "Turn-right magnitude is off; the step may not have been a clean 90°."
            }
        }
        var rollText = "roll step not captured"
        if let roll = captured[.rollRight] {
            let deltaRoll = (level.attitude.inverse * roll.attitude).normalized
            if let axis = Quat.axis(of: deltaRoll) {
                let alignment = abs(simd_dot(axis, forward))
                rollText = String(format: "roll axis · forward = %.2f (expect ≈ 1.00)", alignment)
                if alignment < 0.8 && warning == nil {
                    warning = "The roll cross-check disagrees with the derived nose axis; redo steps 1, 3 and 4."
                }
            }
        }

        cfg.probeNotes = "\(turnText); \(rollText)"
        frames.observed = cfg

        result = Result(text: String(
            format: """
            headForwardLocal = (%+.3f, %+.3f, %+.3f)
            headUpLocal      = (%+.3f, %+.3f, %+.3f)
            headRightLocal   = (%+.3f, %+.3f, %+.3f)
            referenceUpSign  = %+.0f
            %@
            %@
            Saved to FrameConfig.
            """,
            forward.x, forward.y, forward.z,
            up.x, up.y, up.z,
            right.x, right.y, right.z,
            referenceUpSign, turnText, rollText), warning: warning)
    }

    // MARK: Averaging

    static func meanQuaternion(_ qs: [simd_quatd]) -> simd_quatd {
        guard let first = qs.first else { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        var acc = SIMD4<Double>.zero
        for q in qs {
            // Align hemispheres before averaging — q and −q are the same rotation.
            let v = q.vector
            acc += simd_dot(v, first.vector) < 0 ? -v : v
        }
        return simd_quatd(vector: acc / Double(qs.count)).normalized
    }

    static func meanVector(_ vs: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !vs.isEmpty else { return .zero }
        return vs.reduce(.zero, +) / Double(vs.count)
    }
}
