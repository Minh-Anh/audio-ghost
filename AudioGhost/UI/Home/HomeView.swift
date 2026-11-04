import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var editing: Ghost?
    @State private var showSession = false
    @State private var showFrameProbe = false
    @State private var permissions = PermissionCoordinator()
    @State private var startError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let ghost = app.ghost {
                        GhostCard(ghost: ghost)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = ghost }
                        Button {
                            startSession(ghost)
                        } label: {
                            Label("Start session", systemImage: "play.circle.fill")
                                .font(.headline)
                        }
                        .disabled(!ghost.isPlayable)
                        Button("Edit ghost") { editing = ghost }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No ghost yet")
                                .font(.headline)
                            Text("Place a sound at a real-world coordinate, put your AirPods in, and walk around it.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        Button {
                            editing = Ghost()
                        } label: {
                            Label("Create a ghost", systemImage: "plus.circle.fill")
                                .font(.headline)
                        }
                    }
                }

                Section("Permissions") {
                    // iOS won't list the app in Settings until it has asked once, so these rows
                    // do the asking rather than sending the user to a page that isn't there yet.
                    PermissionRow(
                        icon: "location.fill",
                        title: "Location",
                        detail: permissions.status.locationLabel,
                        ok: permissions.status.locationOK,
                        action: permissions.status.canRequestLocation ? "Allow" :
                            (permissions.status.locationOK ? nil : "Settings")) {
                        permissions.requestLocation()
                    }

                    PermissionRow(
                        icon: "airpodspro",
                        title: "Head tracking",
                        detail: permissions.status.motionLabel,
                        ok: permissions.status.motionOK,
                        action: permissions.status.canRequestMotion ? "Allow" :
                            (permissions.status.motionOK || !permissions.status.headTrackingAvailable
                             ? nil : "Settings")) {
                        permissions.requestMotion()
                    }

                    if permissions.isRequestingMotion {
                        Label("Asking for motion access…", systemImage: "ellipsis.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !permissions.status.headTrackingAvailable {
                        Text("Connect AirPods Pro, AirPods (3rd generation or later) or AirPods Max and wear them — iOS can only ask for motion access while they're connected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if DebugSettings.isDebugBuild {
                    Section("Developer") {
                        Button("Frame probe") { showFrameProbe = true }
                        NavigationLink("Desk simulation") { DebugSimulationView() }
                    }
                }
            }
            .navigationTitle("AudioGhost")
            .sheet(item: $editing) { ghost in
                GhostEditorView(ghost: ghost)
            }
            .sheet(isPresented: $showFrameProbe) {
                FrameProbeView()
            }
            .fullScreenCover(isPresented: $showSession) {
                SessionScreenView()
            }
            .alert("Can't start", isPresented: .constant(startError != nil)) {
                Button("OK") { startError = nil }
            } message: {
                Text(startError ?? "")
            }
            .onAppear { permissions.refresh() }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from Settings, or plugging in AirPods, must update the rows.
                if phase == .active { permissions.refresh() }
            }
        }
    }

    private func startSession(_ ghost: Ghost) {
        guard ghost.isPlayable else {
            startError = "This ghost needs an audio file and a location first."
            return
        }
        app.session.start(ghost: ghost)
        showSession = true
    }
}

private struct GhostCard: View {
    let ghost: Ghost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ghost.name).font(.headline)
            if ghost.hasPlacement {
                Text(String(format: "%.5f, %.5f", ghost.latitude, ghost.longitude))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("No location yet").font(.subheadline).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Label(String(format: "%.1f m up", ghost.heightAboveGround), systemImage: "arrow.up")
                if ghost.hasAudio {
                    Label(String(format: "%.0f s", ghost.audioDuration), systemImage: "waveform")
                } else {
                    Label("No audio", systemImage: "waveform.slash").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let ok: Bool
    /// Nil when there is nothing useful to tap (already granted, or blocked on hardware).
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.bordered)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HomeView().environment(AppEnvironment())
}
