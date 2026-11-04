import XCTest
@testable import AudioGhost

/// The editor's Save / Cancel file rules (`AudioEditSession`), against a real `GhostStore` in a
/// temporary directory. Placeholder files stand in for imported .caf files: what is tested is
/// which files survive, not the conversion.
final class AudioEditSessionTests: XCTestCase {

    private var directory: URL!
    private var store: GhostStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioghost-edit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = GhostStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: Helpers

    /// Stands in for `AudioImport.importFile`: writes a uniquely named file into the store.
    private func fakeImport() throws -> String {
        let name = "\(UUID().uuidString).caf"
        try Data([0x01, 0x02]).write(to: store.audioDirectory.appendingPathComponent(name))
        return name
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent(name).path)
    }

    /// A saved ghost with audio, as the editor would receive it from Home.
    private func savedGhost() throws -> Ghost {
        var ghost = Ghost(name: "Saved", latitude: 48.8584, longitude: 2.2945)
        ghost.audioFileName = try fakeImport()
        store.upsert(ghost)
        return ghost
    }

    /// What `GhostEditorView.adopt(importing:)` does.
    private func replaceAudio(of ghost: inout Ghost, in edits: AudioEditSession) throws -> String {
        let name = try fakeImport()
        edits.recordImport(name)
        ghost.audioFileName = name
        return name
    }

    /// What the Save button does, followed by the `.onDisappear` that dismissal triggers.
    private func save(_ ghost: Ghost, _ edits: AudioEditSession) {
        store.upsert(ghost)
        edits.commit(keeping: ghost.audioFileName, in: store.audioDirectory)
        edits.discard(in: store.audioDirectory)
    }

    /// Cancel and swipe-to-dismiss both reduce to the `.onDisappear` discard.
    private func cancel(_ edits: AudioEditSession) {
        edits.discard(in: store.audioDirectory)
    }

    // MARK: Replace once

    func testReplaceThenCancelKeepsSavedAudioAndRemovesImport() throws {
        let saved = try savedGhost()
        var draft = saved
        let edits = AudioEditSession(savedFileName: saved.audioFileName)

        let new = try replaceAudio(of: &draft, in: edits)
        XCTAssertTrue(exists(saved.audioFileName), "import must not delete the saved ghost's file")

        cancel(edits)

        XCTAssertTrue(exists(saved.audioFileName))
        XCTAssertFalse(exists(new), "the abandoned import must not be orphaned")
        let stored = try XCTUnwrap(store.ghosts.first)
        XCTAssertEqual(stored.audioFileName, saved.audioFileName)
        XCTAssertNotNil(store.audioURL(for: stored), "the saved ghost must still be playable")
    }

    func testReplaceThenSaveRemovesOldAudioAndKeepsNew() throws {
        let saved = try savedGhost()
        var draft = saved
        let edits = AudioEditSession(savedFileName: saved.audioFileName)

        let new = try replaceAudio(of: &draft, in: edits)
        save(draft, edits)

        XCTAssertFalse(exists(saved.audioFileName))
        XCTAssertTrue(exists(new))
        let stored = try XCTUnwrap(store.ghosts.first)
        XCTAssertEqual(stored.audioFileName, new)
        XCTAssertNotNil(store.audioURL(for: stored))
    }

    // MARK: Replace twice

    func testDoubleImportThenCancelLeavesOnlySavedAudio() throws {
        let saved = try savedGhost()
        var draft = saved
        let edits = AudioEditSession(savedFileName: saved.audioFileName)

        let first = try replaceAudio(of: &draft, in: edits)
        let second = try replaceAudio(of: &draft, in: edits)
        cancel(edits)

        XCTAssertTrue(exists(saved.audioFileName))
        XCTAssertFalse(exists(first))
        XCTAssertFalse(exists(second))
        XCTAssertEqual(try audioFiles(), [saved.audioFileName])
    }

    func testDoubleImportThenSaveLeavesOnlyLastImport() throws {
        let saved = try savedGhost()
        var draft = saved
        let edits = AudioEditSession(savedFileName: saved.audioFileName)

        let first = try replaceAudio(of: &draft, in: edits)
        let second = try replaceAudio(of: &draft, in: edits)
        save(draft, edits)

        XCTAssertFalse(exists(saved.audioFileName))
        XCTAssertFalse(exists(first))
        XCTAssertTrue(exists(second))
        XCTAssertEqual(try audioFiles(), [second])
        XCTAssertEqual(store.ghosts.first?.audioFileName, second)
    }

    // MARK: Other paths

    func testSaveWithoutReplacingKeepsAudio() throws {
        let saved = try savedGhost()
        var draft = saved
        draft.name = "Renamed"
        let edits = AudioEditSession(savedFileName: saved.audioFileName)

        save(draft, edits)

        XCTAssertTrue(exists(saved.audioFileName))
        XCTAssertEqual(store.ghosts.first?.name, "Renamed")
    }

    func testNewGhostImportThenCancelLeavesNoFiles() throws {
        var draft = Ghost()
        let edits = AudioEditSession(savedFileName: draft.audioFileName)

        _ = try replaceAudio(of: &draft, in: edits)
        cancel(edits)

        XCTAssertEqual(try audioFiles(), [])
        XCTAssertTrue(store.ghosts.isEmpty)
    }

    func testNewGhostImportThenSaveKeepsImport() throws {
        var draft = Ghost(name: "New", latitude: 1, longitude: 1)
        let edits = AudioEditSession(savedFileName: draft.audioFileName)

        let new = try replaceAudio(of: &draft, in: edits)
        save(draft, edits)

        XCTAssertEqual(try audioFiles(), [new])
    }

    /// What the Delete button does after a replace: drop the imports, delete the stored ghost.
    func testReplaceThenDeleteLeavesNoFiles() throws {
        let saved = try savedGhost()
        var draft = saved
        let edits = AudioEditSession(savedFileName: saved.audioFileName)

        _ = try replaceAudio(of: &draft, in: edits)
        edits.discard(in: store.audioDirectory)
        store.delete(store.ghosts.first(where: { $0.id == draft.id }) ?? draft)
        cancel(edits)   // the .onDisappear that follows dismissal

        XCTAssertEqual(try audioFiles(), [])
        XCTAssertTrue(store.ghosts.isEmpty)
    }

    private func audioFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.audioDirectory.path).sorted()
    }
}
