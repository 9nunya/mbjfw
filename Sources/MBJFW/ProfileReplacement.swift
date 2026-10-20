import Foundation

/// Journaled directory replacement. A validated restore can finish after a
/// crash between renames without losing the previous disk directory.
enum ProfileReplacement {
    private struct Journal: Codable {
        let staging: URL
        let destination: URL
        let recovery: URL
    }

    static func commit(staging: URL, destination: URL) throws -> URL? {
        try recover(destination: destination)
        let files = FileManager.default
        let recovery = destination.deletingLastPathComponent().appending(path: "recovery/restore-\(UUID())")
        try files.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = files.fileExists(atPath: destination.path)
        let entry = Journal(staging: staging, destination: destination, recovery: recovery)
        try JSONEncoder().encode(entry).write(to: journalURL(destination), options: .atomic)
        try finish(entry)
        return existed ? recovery : nil
    }

    static func recover(destination: URL) throws {
        let file = journalURL(destination)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let entry = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
        let parent = destination.deletingLastPathComponent().standardizedFileURL.path + "/"
        guard entry.destination.standardizedFileURL == destination.standardizedFileURL,
              entry.staging.standardizedFileURL.path.hasPrefix(parent),
              entry.recovery.standardizedFileURL.path.hasPrefix(parent) else { throw ProfileBackupError.invalidArchive }
        try finish(entry)
    }

    private static func finish(_ entry: Journal) throws {
        let files = FileManager.default
        if files.fileExists(atPath: entry.staging.path) {
            if files.fileExists(atPath: entry.destination.path) {
                guard !files.fileExists(atPath: entry.recovery.path) else { throw ProfileBackupError.invalidArchive }
                try files.moveItem(at: entry.destination, to: entry.recovery)
            }
            try files.moveItem(at: entry.staging, to: entry.destination)
        } else if !files.fileExists(atPath: entry.destination.path) {
            // An incomplete external extraction cannot consume the recovery disk.
            guard files.fileExists(atPath: entry.recovery.path) else { throw ProfileBackupError.invalidArchive }
            try files.moveItem(at: entry.recovery, to: entry.destination)
        }
        try files.removeItem(at: journalURL(entry.destination))
    }

    private static func journalURL(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: "profile-restore-journal.json")
    }
}
