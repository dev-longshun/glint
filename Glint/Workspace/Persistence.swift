import Foundation

enum Persistence {
    private static let fileName = "state.json"

    private static var fileURL: URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = appSupport.appendingPathComponent("Glint", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Returns nil both for "no saved state" (fresh install) and "state was
    /// unreadable" — but the two paths differ in side effects: an unreadable
    /// file is moved aside (never deleted or overwritten) so a decode bug or
    /// half-written file can't silently destroy the user's workspaces. The
    /// caller falls back to `PersistedState.fresh` and the very next autosave
    /// would otherwise clobber the original.
    static func load() -> PersistedState? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(fileName).corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("[glint] failed to decode \(fileName): \(error); moved it aside to \(backup.lastPathComponent) and starting fresh")
            return nil
        }
    }

    static func save(_ state: PersistedState) {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Persistence failing silently is the worst kind of failure —
            // at least leave a trail in the console.
            NSLog("[glint] failed to save \(fileName): \(error)")
        }
    }
}
