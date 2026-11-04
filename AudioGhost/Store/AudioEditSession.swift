import Foundation

/// Tracks the audio files imported while one ghost editor is open, so that deleting files from
/// `GhostStore.audioDirectory` follows the Save / Cancel decision instead of happening at import
/// time. Nothing here deletes a file the saved ghost still references.
///
/// - Import: `recordImport` only; nothing is deleted.
/// - Save: persist the ghost first, then `commit(keeping:in:)` deletes the replaced file and any
///   intermediate imports.
/// - Cancel / swipe-to-dismiss / delete: `discard(in:)` deletes every file imported in this
///   editing session and leaves the saved ghost's file alone.
///
/// Both outcomes empty the import list, so a `discard` after a `commit` (the editor's
/// `.onDisappear` fires after Save too) does nothing.
final class AudioEditSession {

    /// The audio file the saved ghost references ("" for none).
    private(set) var savedFileName: String

    /// Files imported during this editing session and not yet committed, oldest first.
    private(set) var importedFileNames: [String] = []

    init(savedFileName: String) {
        self.savedFileName = savedFileName
    }

    func recordImport(_ fileName: String) {
        importedFileNames.append(fileName)
    }

    /// Call after the ghost has been persisted referencing `keptFileName`.
    func commit(keeping keptFileName: String, in directory: URL) {
        let doomed = (importedFileNames + [savedFileName]).filter { $0 != keptFileName }
        remove(doomed, in: directory)
        savedFileName = keptFileName
        importedFileNames = []
    }

    /// Call when the edit is abandoned.
    func discard(in directory: URL) {
        remove(importedFileNames.filter { $0 != savedFileName }, in: directory)
        importedFileNames = []
    }

    private func remove(_ fileNames: [String], in directory: URL) {
        for name in fileNames where !name.isEmpty {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
