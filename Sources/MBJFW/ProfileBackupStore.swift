import CryptoKit
import Foundation

@MainActor
enum ProfileBackupStore {
    static func create(account: PlayerAccount, source: URL) async throws -> URL {
        let hasDeviceDisk = ["userdata-qemu.img.qcow2", "userdata-qemu.img", "userdata.img"].contains { name in
            let file = source.appending(path: name)
            return FileManager.default.fileExists(atPath: file.path)
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
        guard hasDeviceDisk else { throw ProfileBackupError.noProfileData }
        let backups = source.deletingLastPathComponent().appending(path: "backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let archive = backups.appending(path: "\(date)-\(account.id.uuidString).zip")
        let log = backups.appending(path: "backup.log")
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path],
            environment: [:], logURL: log
        )
        do {
            _ = try await AndroidProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-t", archive.path], environment: [:], logURL: log)
            let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let digest = try sha256(archive)
            let manifest = BackupManifest(profileID: account.id, profileName: account.name, createdAt: .now, archiveBytes: size, sha256: digest)
            let encoded = try JSONEncoder().encode(manifest)
            try encoded.write(to: archive.appendingPathExtension("json"), options: .atomic)
            return archive
        } catch {
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
    }

    static func restore(archive: URL, account: PlayerAccount, destination: URL) async throws -> URL? {
        let hasScope = archive.startAccessingSecurityScopedResource()
        defer { if hasScope { archive.stopAccessingSecurityScopedResource() } }
        let parent = destination.deletingLastPathComponent()
        let manifestURL = archive.appendingPathExtension("json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData),
              manifest.profileID == account.id,
              try sha256(archive) == manifest.sha256 else { throw ProfileBackupError.unverifiedArchive }
        let staging = parent.appending(path: ".restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let log = parent.appending(path: "restore.log")
        _ = try await AndroidProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-t", archive.path], environment: [:], logURL: log)
        try await AndroidProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, staging.path], environment: [:], logURL: log)
        let restored = staging.appending(path: "android-avd")
        let candidates = ["userdata-qemu.img.qcow2", "userdata-qemu.img", "userdata.img"]
        guard candidates.contains(where: { name in
            let file = restored.appending(path: name)
            return FileManager.default.fileExists(atPath: file.path) && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }) else { throw ProfileBackupError.invalidArchive }

        let recovery = try ProfileReplacement.commit(staging: restored, destination: destination)
        try? FileManager.default.removeItem(at: parent.appending(path: "installed-minecraft.json"))
        return recovery
    }

    static func list(for account: PlayerAccount, accountDirectory: URL) throws -> [URL] {
        let root = accountDirectory.appending(path: "backups")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "zip" && $0.lastPathComponent.contains(account.id.uuidString) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct BackupManifest: Codable {
    let profileID: UUID
    let profileName: String
    let createdAt: Date
    let archiveBytes: Int64
    let sha256: String
}

enum ProfileBackupError: LocalizedError {
    case invalidArchive
    case unverifiedArchive
    case noProfileData

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "This archive does not contain a valid Android profile disk."
        case .unverifiedArchive: "The backup could not be verified for this profile."
        case .noProfileData: "This profile has no Android save data to back up yet."
        }
    }
}
