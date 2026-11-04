import SwiftUI

/// The compass-assisted ritual (spec §6.3) as full-screen pages, ending on the verification arrow
/// — which doubles as the fastest field diagnostic in the app.
struct CalibrationFlowView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = CalibrationFlowModel()

    var body: some View {
        VStack(spacing: 28) {
            switch model.stage {
            case .instructions:
                instructions
            case .measuring:
                measuring
            case .failed(let error):
                failure(error)
            case .verify(let offset):
                verify(offset)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { model.attach(session: app.session) }
        .onDisappear { model.cancel() }
    }

    // MARK: Pages

    private var instructions: some View {
        VStack(spacing: 24) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Point the phone where your nose points")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Hold the phone flat in front of you, like a compass, facing the same direction as your face. Stand still for two seconds.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.beginMeasurement()
            } label: {
                Text("Start").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Skip for now") { dismiss() }
                .font(.footnote)
        }
    }

    private var measuring: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(model.progress * 100))%")
                    .font(.title.monospacedDigit())
            }
            .frame(width: 160, height: 160)
            Text(model.waitingForCompass ? "Waiting for the compass…" : "Hold still…")
                .font(.headline)
            if model.needsFigureEight {
                Text("The compass needs calibrating — wave the phone in a figure 8.")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Text(model.liveReadout)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.cancel(); dismiss() }
        }
    }

    private func failure(_ error: CalibrationError) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Didn't get a clean reading")
                .font(.title3.bold())
            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.beginMeasurement()
            } label: {
                Text("Try again").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Use walking calibration instead") { dismiss() }
                .font(.footnote)
        }
    }

    private func verify(_ offset: Double) -> some View {
        VStack(spacing: 20) {
            Text("Does the arrow point at your ghost?")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            // Use the *candidate* offset, not the committed one — this page is what decides
            // whether the candidate gets committed at all.
            let candidateTrueYaw = wrapToPi(app.session.snapshot.attitudeYaw + offset)
            let relative = wrapToPi(app.session.snapshot.render.bearing - candidateTrueYaw)
            Image(systemName: "arrow.up")
                .font(.system(size: 96, weight: .bold))
                .rotationEffect(.radians(relative))
                .animation(.easeOut(duration: 0.15), value: relative)
                .foregroundStyle(.tint)
                .frame(height: 160)

            Text(String(format: "%.0f m away, %@ of you",
                        app.session.snapshot.render.trueDistance,
                        compassLabel(bearingRadians: app.session.snapshot.render.bearing)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(String(format: "yaw offset %.1f°", offset.degrees))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
            Button {
                app.session.applyCalibration(offset: offset)
                dismiss()
            } label: {
                Text("Looks right").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Redo") { model.beginMeasurement() }
        }
    }
}

/// Collects the concurrent heading / attitude samples and runs `CalibrationService.solveRitual`.
@Observable
final class CalibrationFlowModel {

    enum Stage: Equatable {
        case instructions
        case measuring
        case failed(CalibrationError)
        case verify(Double)
    }

    private(set) var stage: Stage = .instructions
    private(set) var progress: Double = 0
    private(set) var needsFigureEight = false
    private(set) var waitingForCompass = false
    private(set) var liveReadout = ""

    private weak var session: SessionCoordinator?
    private var headings: [Double] = []
    private var accuracies: [Double] = []
    /// Every update CoreLocation delivered, valid or not — distinguishes "the compass is silent"
    /// from "the compass is talking but has no true north yet".
    private var rawHeadingUpdates = 0
    private var attitudes: [Double] = []
    private var timer: Timer?
    private var startTime = Date()

    func attach(session: SessionCoordinator) {
        self.session = session
    }

    /// Hard ceiling on the collection window: the ritual asks the user to stand still, and a slow
    /// or busy compass shouldn't fail them at the 2 s mark if samples are still arriving.
    private static let maximumWait: TimeInterval = 6

    func beginMeasurement() {
        guard let session else { return }
        guard session.headingProvider?.isHeadingAvailable ?? false else {
            stage = .failed(.compassUnavailable)
            return
        }
        headings.removeAll(); accuracies.removeAll(); attitudes.removeAll()
        rawHeadingUpdates = 0
        needsFigureEight = false
        waitingForCompass = false
        progress = 0
        stage = .measuring
        startTime = Date()

        session.headingProvider?.onHeading = { [weak self] sample in
            guard let self else { return }
            self.rawHeadingUpdates += 1
            if sample.accuracyDegrees < 0 {
                self.needsFigureEight = true
            }
            // Readings without a valid true heading are dropped rather than averaged: calibrating
            // `yawOffset` against CoreLocation's −1 placeholder would be silently, badly wrong.
            guard sample.isTrueHeadingValid else { return }
            self.headings.append(sample.trueHeadingRadians)
            self.accuracies.append(sample.accuracyDegrees)
        }
        session.headingProvider?.startHeading()

        // Sample the head attitude on the same window at ~20 Hz.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let session = self.session else { return }
            let yaw = session.currentAttitudeYaw
            self.attitudes.append(yaw)
            let elapsed = Date().timeIntervalSince(self.startTime)
            self.progress = min(1, elapsed / Tuning.current.calibrationSampleDuration)
            let enoughHeadings = self.headings.count >= CalibrationService.minimumRitualSamples
            self.liveReadout = String(format: "compass %d · head yaw %.0f°",
                                      self.headings.count, yaw.degrees)
            self.waitingForCompass = elapsed >= Tuning.current.calibrationSampleDuration && !enoughHeadings

            // Finish on time if the compass kept up; otherwise keep collecting until the ceiling.
            if elapsed >= Tuning.current.calibrationSampleDuration, enoughHeadings || elapsed >= Self.maximumWait {
                self.finish()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        session?.headingProvider?.stopHeading()
        session?.headingProvider?.onHeading = nil
    }

    private func finish() {
        cancel()

        // The compass was reporting, but never with a usable true heading: that is a missing GPS
        // fix, not a shaky hand, and telling the user to "hold still" would send them in circles.
        if headings.isEmpty, rawHeadingUpdates > 0 {
            stage = .failed(.trueNorthUnavailable)
            return
        }

        switch CalibrationService.solveRitual(headings: headings,
                                              headingAccuracies: accuracies,
                                              attitudeYaws: attitudes) {
        case .success(let offset):
            stage = .verify(offset)
        case .failure(let error):
            stage = .failed(error)
        }
    }
}
