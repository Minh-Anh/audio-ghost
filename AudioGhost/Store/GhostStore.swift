import Foundation
import Observation

/// Atomic JSON-file persistence for ghosts plus their copied audio assets (spec §4).
/// Architected for N ghosts; the MVP UI only exposes the first one.
@Observable
final class GhostStore {

    private(set) var ghosts: [Ghost] = []

    /// True while a session holds the store read-only (imports are disallowed mid-session).
    var isLocked: Bool = false

    let audioDirectory: URL
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("ghosts.json")
        audioDirectory = base.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        load()
    }

    func audioURL(for ghost: Ghost) -> URL? {
        guard ghost.hasAudio else { return nil }
        let url = audioDirectory.appendingPathComponent(ghost.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Mutation

    func upsert(_ ghost: Ghost) {
        if let idx = ghosts.firstIndex(where: { $0.id == ghost.id }) {
            ghosts[idx] = ghost
        } else {
            ghosts.append(ghost)
        }
        save()
    }

    func delete(_ ghost: Ghost) {
        if let url = audioURL(for: ghost) { try? FileManager.default.removeItem(at: url) }
        ghosts.removeAll { $0.id == ghost.id }
        save()
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        ghosts = (try? JSONDecoder().decode([Ghost].self, from: data)) ?? []
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ghosts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("GhostStore save failed: \(error.localizedDescription)")
        }
    }
}
