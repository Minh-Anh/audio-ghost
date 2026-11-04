import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

/// Name, audio, coordinates (drop-here / manual / draggable pin), height, advanced knobs (§9.2).
struct GhostEditorView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var ghost: Ghost
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var errorMessage: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var probe = LiveLocationProbe()
    @State private var showAdvanced = false
    @State private var pinFollowsMap = false
    /// Defers audio-file deletion until Save or Cancel (see `AudioEditSession`).
    @State private var audioEdits: AudioEditSession

    init(ghost: Ghost) {
        _ghost = State(initialValue: ghost)
        _audioEdits = State(initialValue: AudioEditSession(savedFileName: ghost.audioFileName))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Ghost", text: $ghost.name)
                }
                soundSection
                whereSection
                heightSection
                advancedSection
                if app.store.ghosts.contains(where: { $0.id == ghost.id }) {
                    Section {
                        Button("Delete ghost", role: .destructive) {
                            // Drop this session's imports, then delete the ghost as saved, so
                            // `delete` removes the file the stored ghost actually references.
                            audioEdits.discard(in: app.store.audioDirectory)
                            app.store.delete(app.store.ghosts.first(where: { $0.id == ghost.id }) ?? ghost)
                            dismiss()
                        }
                        .disabled(app.store.isLocked)
                    }
                }
            }
            .navigationTitle("Ghost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.store.upsert(ghost)
                        audioEdits.commit(keeping: ghost.audioFileName, in: app.store.audioDirectory)
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("Import problem", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                syncTextFields()
                probe.start()
                if ghost.hasPlacement {
                    centerMap(on: CLLocationCoordinate2D(latitude: ghost.latitude, longitude: ghost.longitude))
                }
            }
            .onDisappear {
                probe.stop()
                // Cancel and swipe-to-dismiss both land here. After Save or Delete this is a no-op.
                audioEdits.discard(in: app.store.audioDirectory)
            }
        }
    }

    // MARK: Sections

    private var soundSection: some View {
        Section("Sound") {
            Button {
                showImporter = true
            } label: {
                Label(ghost.hasAudio ? "Replace audio file" : "Choose audio file",
                      systemImage: "waveform")
            }
            .disabled(app.store.isLocked)
            Button {
                useDemoSound()
            } label: {
                Label("Use the demo drone", systemImage: "sparkles")
            }
            .disabled(app.store.isLocked)
            if ghost.hasAudio {
                LabeledContent("Length", value: String(format: "%.1f s", ghost.audioDuration))
                Text(ghost.audioNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let importMessage {
                Text(importMessage).font(.footnote).foregroundStyle(.green)
            }
        }
    }

    private var whereSection: some View {
        Section("Where") {
            Button {
                dropHere()
            } label: {
                HStack {
                    Label("Drop here", systemImage: "mappin.and.ellipse")
                    Spacer()
                    Text(probe.accuracyLabel)
                        .font(.caption)
                        .foregroundStyle(probe.isGoodEnough ? Color.secondary : Color.orange)
                }
            }
            .disabled(probe.current == nil && probe.authorization == .authorized)

            if let fix = probe.current, fix.horizontalAccuracy > Tuning.current.dropHereAccuracy {
                Text("GPS accuracy is ±\(Int(fix.horizontalAccuracy)) m — you can still drop here, but the anchor will be off by about that much.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                TextField("Latitude", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: latitudeText) { _, new in parse(new, into: \.latitude, limit: 90) }
                Divider()
                TextField("Longitude", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: longitudeText) { _, new in parse(new, into: \.longitude, limit: 180) }
            }
            .font(.system(.body, design: .monospaced))

            Text("Tip: paste \"48.8584, 2.2945\" into either field.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if ghost.hasPlacement {
                Map(position: $camera) {
                    Marker(ghost.name, coordinate: CLLocationCoordinate2D(
                        latitude: ghost.latitude, longitude: ghost.longitude))
                    UserAnnotation()
                }
                .frame(height: 220)
                .onMapCameraChange(frequency: .onEnd) { context in
                    // Dragging the map re-places the pin at its center: the cheapest
                    // sanity check in the app (§9.2).
                    if pinFollowsMap {
                        ghost.latitude = context.camera.centerCoordinate.latitude
                        ghost.longitude = context.camera.centerCoordinate.longitude
                        syncTextFields()
                    }
                }
                .overlay(alignment: .center) {
                    if pinFollowsMap {
                        Image(systemName: "plus")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
                Toggle("Move pin to map center", isOn: $pinFollowsMap)
                    .font(.footnote)
            }
        }
    }

    private var heightSection: some View {
        Section("Height") {
            VStack(alignment: .leading) {
                Slider(value: $ghost.heightAboveGround, in: 0...30, step: 0.5)
                Text(String(format: "%.1f m above the ground where you're standing",
                            ghost.heightAboveGround))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading) {
                    Text(String(format: "Rolloff %.2f", ghost.rolloffFactor)).font(.footnote)
                    Slider(value: $ghost.rolloffFactor, in: 0.3...2.0, step: 0.05)
                    Text("Lower = audible further away. Expect to land near 0.6–0.8 outdoors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Cull distance %.0f m", ghost.cullDistance)).font(.footnote)
                    Slider(value: $ghost.cullDistance, in: 50...1000, step: 10)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Level trim %.1f dB", ghost.referenceLevelDB)).font(.footnote)
                    Slider(value: $ghost.referenceLevelDB, in: -24...12, step: 0.5)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Your ear height %.2f m", Tuning.current.listenerEarHeight)).font(.footnote)
                    Slider(value: Binding(get: { Tuning.current.listenerEarHeight },
                                          set: { Tuning.current.listenerEarHeight = $0; Tuning.saveOverrides() }),
                           in: 1.0...2.2, step: 0.01)
                }
            }
        }
    }

    // MARK: Actions

    private func dropHere() {
        // First tap with no decision yet raises the prompt; the fix arrives moments later and the
        // user taps again with a real accuracy reading in front of them.
        guard probe.authorization == .authorized else {
            probe.requestAccess()
            return
        }
        guard let fix = probe.current else { return }
        ghost.latitude = fix.coordinate.latitude
        ghost.longitude = fix.coordinate.longitude
        syncTextFields()
        centerMap(on: fix.coordinate)
    }

    private func centerMap(on center: CLLocationCoordinate2D) {
        camera = .region(MKCoordinateRegion(center: center, latitudinalMeters: 200, longitudinalMeters: 200))
    }

    private func syncTextFields() {
        latitudeText = ghost.hasPlacement ? String(format: "%.6f", ghost.latitude) : ""
        longitudeText = ghost.hasPlacement ? String(format: "%.6f", ghost.longitude) : ""
    }

    /// Accepts either a single number or a pasted "lat, lon" pair in either field.
    private func parse(_ text: String, into field: WritableKeyPath<Ghost, Double>, limit: Double) {
        if let pair = Geo.parseCoordinatePair(text) {
            ghost.coordinate = pair
            syncTextFields()
        } else if let v = Double(text), abs(v) <= limit {
            ghost[keyPath: field] = v
        }
    }

    /// A bundled six-second seamless drone, so a fresh install is testable immediately.
    private func useDemoSound() {
        guard let url = Bundle.main.url(forResource: "demo-ghost", withExtension: "wav") else {
            errorMessage = "The demo sound is missing from the app bundle."
            return
        }
        adopt(importing: url)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard !app.store.isLocked else {
            errorMessage = "Stop the running session before changing the audio."
            return
        }
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            adopt(importing: url)
        }
    }

    private func adopt(importing url: URL) {
        do {
            let imported = try AudioImport.importFile(from: url, into: app.store.audioDirectory)
            // Nothing is deleted here: the saved ghost may still reference the old file until Save.
            audioEdits.recordImport(imported.fileName)
            ghost.audioFileName = imported.fileName
            ghost.audioDuration = imported.duration
            ghost.audioNote = imported.note
            importMessage = imported.note
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A tiny standalone CoreLocation reader for the editor's "Drop here" button. The session's
/// `LocationService` is deliberately not reused: the editor must work before a session exists.
@Observable
final class LiveLocationProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var current: CLLocation?
    private(set) var authorization: LocationAuthorization = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorization = LocationAuthorization(manager.authorizationStatus)
    }

    var accuracyLabel: String {
        switch authorization {
        case .notDetermined: return "tap to allow"
        case .denied, .restricted: return "location denied"
        case .authorized: break
        }
        guard let current else { return "acquiring…" }
        return "±\(Int(current.horizontalAccuracy)) m"
    }

    var isGoodEnough: Bool {
        guard let current else { return false }
        return current.horizontalAccuracy <= Tuning.current.dropHereAccuracy
    }

    /// Never requests permission on its own — merely appearing on screen is not a reason to raise
    /// a system prompt, and doing so made the UI smoke tests pop a real alert in the test host.
    /// The prompt belongs to an explicit tap (Home's Allow button, or "Drop here").
    func start() {
        guard authorization == .authorized else { return }
        manager.startUpdatingLocation()
    }

    /// Called from the "Drop here" button when access hasn't been decided yet.
    func requestAccess() {
        guard authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func stop() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy > 0 else { return }
        current = last
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = LocationAuthorization(manager.authorizationStatus)
        if authorization == .authorized { manager.startUpdatingLocation() }
    }
}
