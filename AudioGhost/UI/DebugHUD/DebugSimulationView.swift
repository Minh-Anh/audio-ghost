import SwiftUI

/// Desk simulation controls (spec §11.2): scripted GPS paths and a synthetic head, so the
/// approach / circle / fly-by scenarios can be *heard* from a chair.
struct DebugSimulationView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var debug = app.debug
        return Form {
            Section("GPS") {
                Picker("Scripted path", selection: $debug.scriptedPath) {
                    Text("Real GPS").tag(ScriptedLocationProvider.Path?.none)
                    ForEach(ScriptedLocationProvider.Path.allCases) { path in
                        Text(path.title).tag(ScriptedLocationProvider.Path?.some(path))
                    }
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Noise σ %.1f m", debug.scriptedNoiseSigma)).font(.footnote)
                    Slider(value: $debug.scriptedNoiseSigma, in: 0...15, step: 0.5)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Reported accuracy %.0f m", debug.scriptedReportedAccuracy)).font(.footnote)
                    Slider(value: $debug.scriptedReportedAccuracy, in: 3...30, step: 1)
                }
            }
            Section("Head tracking") {
                Toggle("Synthetic head (no AirPods)", isOn: $debug.useSyntheticHeadTracking)
                Toggle("Allow non-headphone route", isOn: $debug.allowNonHeadphoneRoute)
            }
            Section {
                Text("Changes take effect the next time you start a session. The scripted path is played relative to the ghost's coordinate through the same filter and clamp as real fixes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Desk simulation")
        .navigationBarTitleDisplayMode(.inline)
    }
}
