import SwiftUI

/// Everything the §15 troubleshooting tree asks you to look at, in one place (spec §9.5).
struct DebugHUDView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var export: ExportItem?
    @State private var showTuning = false
    @State private var showFlips = false

    private var s: SessionSnapshot { app.session.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group("Position") {
                row("raw−smoothed", String(format: "%.2f m", s.rawSmoothedDelta))
                row("accuracy", String(format: "%.1f m", s.horizontalAccuracy))
                row("fix age", s.fixAge.isFinite ? String(format: "%.2f s", s.fixAge) : "—")
                row("ENU", String(format: "E %.1f  N %.1f", s.enuPosition.x, s.enuPosition.y))
                row("fixes", "\(s.acceptedFixes) ok / \(s.rejectedFixes) rejected")
                if !s.lastRejection.isEmpty { row("last reject", s.lastRejection) }
            }
            group("Yaw") {
                row("attitudeYaw", deg(s.attitudeYaw))
                row("yawOffset", deg(s.yawOffset))
                row("trueYaw", deg(s.trueYaw))
                row("pitch", deg(s.pitch))
                row("course", s.course >= 0 ? String(format: "%.0f°", s.course) : "—")
                row("courseErr", s.courseError.map { deg($0) } ?? "—")
                row("calibration", s.calibrationQuality.rawValue)
            }
            group("Render") {
                row("distance", String(format: "%.1f m (rendered %.1f)", s.render.trueDistance, s.render.renderedDistance))
                row("bearing", deg(s.render.bearing))
                row("elevation", String(format: "%.1f m", s.render.elevation))
                row("clamp", s.render.clampActive ? "ACTIVE" : "off")
                row("event", s.render.isPlaying ? "playing" : "stopped")
            }
            group("Rates") {
                row("motion", String(format: "%.1f Hz (age %.2f s)", s.motionHz, s.motionAge))
                row("route", s.routeName)
                row("log rows", "\(app.session.logger.count)")
            }

            HStack {
                Button("Export CSV") { exportCSV() }
                Button("Sign flips") { showFlips = true }
                Button("Tuning") { showTuning = true }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showTuning) { TuningSheet() }
        .sheet(isPresented: $showFlips) { SignFlipSheet() }
        .sheet(item: $export) { item in ShareSheet(url: item.url) }
    }

    private func exportCSV() {
        do {
            export = ExportItem(url: try app.session.logger.exportCSV())
        } catch {
            Log.error("CSV export failed: \(error.localizedDescription)")
        }
    }

    private func deg(_ r: Double) -> String { String(format: "%.1f°", r.degrees) }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            content()
        }
    }
}

private struct ExportItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Live overrides for every §12 constant, so field tuning doesn't require a rebuild.
struct TuningSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// `Tuning.current` isn't observable, so the sheet edits its own copy and writes through.
    @State private var tuning = Tuning.current

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Tuning.knobs) { knob in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(knob.label).font(.footnote)
                            Spacer()
                            Text(label(for: knob))
                                .font(.system(.caption, design: .monospaced))
                        }
                        Slider(value: binding(for: knob), in: knob.range)
                    }
                }
                Section {
                    Button("Reset to spec defaults", role: .destructive) {
                        Tuning.resetOverrides()
                        tuning = Tuning.current
                    }
                }
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func label(for knob: Tuning.Knob) -> String {
        let value = tuning[keyPath: knob.path]
        return knob.isAngle ? String(format: "%.0f°", value.degrees) : String(format: "%.3f", value)
    }

    private func binding(for knob: Tuning.Knob) -> Binding<Double> {
        Binding(get: { tuning[keyPath: knob.path] },
                set: { value in
                    tuning[keyPath: knob.path] = value
                    Tuning.current[keyPath: knob.path] = value
                    Tuning.saveOverrides()
                })
    }
}

/// The §15 field-walk troubleshooting tree, as four switches.
struct SignFlipSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var frames = app.frames
        return NavigationStack {
            Form {
                Section("Field-walk troubleshooting (§15)") {
                    Toggle("1. Left/right mirrored — flip east", isOn: $frames.observed.flipEast)
                    Toggle("2. Front/back mirrored — flip north", isOn: $frames.observed.flipNorth)
                    Toggle("4. World rotates with your head — conjugate listener",
                           isOn: $frames.observed.conjugateListener)
                    Toggle("5. Constant offset calibration can't fix — flip yaw offset sign",
                           isOn: $frames.observed.flipYawOffsetSign)
                }
                Section("Measured frame") {
                    LabeledContent("forward", value: vector(frames.observed.headForwardLocal))
                    LabeledContent("up", value: vector(frames.observed.headUpLocal))
                    LabeledContent("reference up", value: frames.observed.referenceUpSign >= 0 ? "+z" : "−z")
                    LabeledContent("probed", value: frames.observed.probedAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "never — run FrameProbe")
                }
                Section {
                    Text("3. Head turns sweep the source ~2× ⇒ the OS spatializer is also rotating: turn off head-tracked Spatial Audio for AudioGhost (Control Centre → long-press volume).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sign flips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func vector(_ v: SIMD3<Double>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }
}
