import XCTest
import AVFAudio
import simd
@testable import AudioGhost

/// End-to-end desk run: bundled demo audio → import pipeline → store → session coordinator with
/// the synthetic head provider and a scripted GPS path → PHASE graph → snapshots.
///
/// This is the test that catches wiring mistakes the pure-function tests cannot: a state machine
/// that never leaves `acquiringFix`, an audio graph that throws on registration, a heartbeat that
/// never reaches the UI.
final class SessionIntegrationTests: XCTestCase {

    private var directory: URL!
    private var store: GhostStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Tuning.resetOverrides()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioghost-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = GhostStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func demoURL() throws -> URL {
        let bundle = Bundle(for: SessionIntegrationTests.self)
        if let url = bundle.url(forResource: "demo-ghost", withExtension: "wav") { return url }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "demo-ghost", withExtension: "wav"),
                                "the bundled demo drone must ship with the app")
        return url
    }

    // MARK: Import pipeline

    func testImportProducesAMonoNormalisedAsset() throws {
        let imported = try AudioImport.importFile(from: demoURL(), into: store.audioDirectoryURL)
        XCTAssertEqual(imported.duration, 6, accuracy: 0.05)
        XCTAssertTrue(imported.fileName.hasSuffix(".caf"))

        let url = store.audioDirectoryURL.appendingPathComponent(imported.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 1, "assets must be mono for PHASE")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var peak: Float = 0
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][i])) }
        XCTAssertEqual(peak, AudioImport.targetPeak, accuracy: 0.01, "peak-normalised to −1 dBFS")
    }

    func testImportRejectsAnEmptyFile() throws {
        let empty = directory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        XCTAssertThrowsError(try AudioImport.importFile(from: empty, into: store.audioDirectoryURL))
    }

    // MARK: Store

    func testStorePersistsAcrossInstances() throws {
        var ghost = Ghost(name: "Fountain", latitude: 43.949317, longitude: 4.805528)
        ghost.audioFileName = "x.caf"
        store.upsert(ghost)

        let reopened = GhostStore(directory: directory)
        XCTAssertEqual(reopened.ghosts.count, 1)
        XCTAssertEqual(reopened.ghosts.first?.name, "Fountain")
        XCTAssertEqual(reopened.ghosts.first?.latitude ?? 0, 43.949317, accuracy: 1e-9)
    }

    func testDeleteRemovesTheAudioFile() throws {
        let imported = try AudioImport.importFile(from: demoURL(), into: store.audioDirectoryURL)
        var ghost = Ghost(name: "Doomed", latitude: 1, longitude: 1)
        ghost.audioFileName = imported.fileName
        store.upsert(ghost)
        let url = try XCTUnwrap(store.audioURL(for: ghost))
        store.delete(ghost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.ghosts.isEmpty)
    }

    // MARK: The whole pipeline

    func testDeskRunReachesAwaitingCalibrationAndPlays() throws {
        let imported = try AudioImport.importFile(from: demoURL(), into: store.audioDirectoryURL)
        var ghost = Ghost(name: "Desk ghost", latitude: 43.949317, longitude: 4.805528)
        ghost.audioFileName = imported.fileName
        ghost.heightAboveGround = 3
        store.upsert(ghost)

        let debug = DebugSettings()
        debug.useSyntheticHeadTracking = true
        debug.scriptedPath = .approach100
        debug.scriptedNoiseSigma = 2
        debug.allowNonHeadphoneRoute = true          // the simulator has no headphones

        let frames = FrameConfigStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let session = SessionCoordinator(store: store, debug: debug, frames: frames)

        session.start(ghost: ghost)

        // 1. The state machine must leave `acquiringFix` once the scripted provider delivers.
        expect("leaves acquiringFix", timeout: 10) {
            if case .awaitingCalibration = session.state { return true }
            if case .running = session.state { return true }
            return false
        }

        // 2. Audio must be running: PHASE graph built, event started.
        expect("audio event playing", timeout: 5) { session.snapshot.render.isPlaying }

        // 3. The heartbeat must be feeding the UI, and the geometry must be sane: the scripted
        //    approach starts 100 m south of the ghost, which is 1.4 m above ear level.
        expect("snapshot has geometry", timeout: 5) { session.snapshot.render.trueDistance > 50 }
        XCTAssertEqual(session.snapshot.render.bearing, 0, accuracy: (12.0).radians,
                       "the ghost must bear roughly north of a listener approaching from the south")
        XCTAssertEqual(session.snapshot.render.elevation, 3 - Tuning.listenerEarHeight, accuracy: 1e-6)
        // The heartbeat's real rate, measured from the log rows rather than trusted from a
        // provider-reported number: the spec marks ~25 Hz as [EMPIRICAL].
        let rowsBefore = session.logger.count
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let rowsPerSecond = session.logger.count - rowsBefore
        XCTAssertGreaterThan(rowsPerSecond, 10, "heartbeat too slow: \(rowsPerSecond) ticks/s")
        XCTAssertGreaterThan(session.snapshot.motionHz, 5, "the heartbeat must be ticking")

        // 4. Calibration is not yet valid, so audio plays unaligned rather than not at all.
        XCTAssertEqual(session.snapshot.calibrationQuality, .none)
        XCTAssertTrue(session.needsCalibration)

        // 5. A precise calibration promotes the session to running.
        session.applyCalibration(offset: 0.3)
        expect("running after calibration", timeout: 5) {
            session.state == .running(quality: .precise)
        }

        // 6. The exported CSV must parse back into a replay fixture.
        let csv = session.logger.csv()
        XCTAssertTrue(csv.hasPrefix(SessionLogger.header))
        let replay = ReplayLocationProvider(csv: csv, queue: DispatchQueue(label: "replay"))
        XCTAssertNotNil(replay, "every field CSV must be replayable")
        XCTAssertGreaterThan(replay?.rows.count ?? 0, 0)

        // 7. Stopping tears everything down.
        session.stop()
        expect("returns to idle", timeout: 5) { session.state == .idle }
        XCTAssertFalse(store.isLocked)
    }

    /// Weak-but-usable fixes must produce `degraded(.accuracyPoor)` — the "GPS is weak here"
    /// banner — rather than being masked by the staleness path or clearing themselves.
    func testSustainedWeakFixesDegradeTheSession() throws {
        let imported = try AudioImport.importFile(from: demoURL(), into: store.audioDirectoryURL)
        var ghost = Ghost(name: "Weak GPS", latitude: 43.949317, longitude: 4.805528)
        ghost.audioFileName = imported.fileName
        store.upsert(ghost)

        Tuning.accuracyPoorTimeout = 0.5          // 15 s is correct in the field, not in a test
        defer { Tuning.resetOverrides() }

        let debug = DebugSettings()
        debug.useSyntheticHeadTracking = true
        debug.scriptedPath = .rotateInPlace30
        debug.scriptedReportedAccuracy = 25       // accepted (< 30 m) but weak (> 15 m)
        debug.scriptedNoiseSigma = 1
        debug.allowNonHeadphoneRoute = true

        let frames = FrameConfigStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let session = SessionCoordinator(store: store, debug: debug, frames: frames)
        session.start(ghost: ghost)

        // GPS complaints are suppressed until the session is actually running — while awaiting
        // calibration the banner has something more actionable to say.
        expect("reaches awaitingCalibration", timeout: 10) { session.state == .awaitingCalibration }
        session.applyCalibration(offset: 0)

        expect("degrades on weak GPS", timeout: 10) {
            session.state == .degraded(reason: .accuracyPoor)
        }
        XCTAssertTrue(session.state.shouldPlayAudio, "degraded must keep playing")
        session.stop()
    }

    func testStartingAnIncompleteGhostFails() {
        let debug = DebugSettings()
        let frames = FrameConfigStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let session = SessionCoordinator(store: store, debug: debug, frames: frames)
        session.start(ghost: Ghost(name: "No audio", latitude: 1, longitude: 1))
        expect("fails fast", timeout: 3) { session.state == .failed(.ghostIncomplete) }
    }

    // MARK: Helper

    private func expect(_ description: String, timeout: TimeInterval,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }
}

