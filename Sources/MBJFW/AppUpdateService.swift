import AppKit
import Foundation

@MainActor
enum AppUpdateService {
    private static let repository = "9nunya/mbjfw"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func checkAndPrompt() async {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let update = try? await availableUpdate(currentVersion: currentVersion) else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "MBJFW \(update.version) is available"
        alert.informativeText = "Download and verify the installer for this Mac, then open it in macOS Installer?"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let package = try await downloadAndVerify(update)
            guard NSWorkspace.shared.open(package) else { throw UpdateError.installerCouldNotOpen }
        } catch {
            let failure = NSAlert(error: error)
            failure.alertStyle = .warning
            failure.runModal()
        }
    }

    private static func availableUpdate(currentVersion: String) async throws -> AppUpdate? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MBJFW-macOS-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return nil }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = String(release.tagName.drop(while: { $0 == "v" }))
        guard ReleaseVersion.isNewer(version, than: currentVersion) else { return nil }

        let architecture = RuntimeArchitecture.current.rawValue
        let packageName = "MBJFW-\(version)-macos-\(architecture).pkg"
        let sidecarName = packageName + ".sha256"
        guard let packageAsset = release.assets.first(where: { $0.name == packageName }),
              let checksumAsset = release.assets.first(where: { $0.name == sidecarName }),
              let packageURL = trustedReleaseAsset(packageAsset.browserDownloadURL),
              let checksumURL = trustedReleaseAsset(checksumAsset.browserDownloadURL) else { return nil }
        return AppUpdate(version: version, packageName: packageName, packageURL: packageURL, checksumURL: checksumURL)
    }

    private static func downloadAndVerify(_ update: AppUpdate) async throws -> URL {
        var checksumRequest = URLRequest(url: update.checksumURL)
        checksumRequest.setValue("MBJFW-macOS-Updater", forHTTPHeaderField: "User-Agent")
        let (checksumData, checksumResponse) = try await session.data(for: checksumRequest)
        guard let checksumResponse = checksumResponse as? HTTPURLResponse, checksumResponse.statusCode == 200,
              let expectedHash = String(data: checksumData, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first,
              expectedHash.count == 64, expectedHash.allSatisfy(\.isHexDigit) else {
            throw UpdateError.invalidChecksumFile
        }

        var packageRequest = URLRequest(url: update.packageURL)
        packageRequest.setValue("MBJFW-macOS-Updater", forHTTPHeaderField: "User-Agent")
        let (temporaryFile, packageResponse) = try await session.download(for: packageRequest)
        guard let packageResponse = packageResponse as? HTTPURLResponse, packageResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "MBJFW/Updates", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let destination = cacheRoot.appending(path: update.packageName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
        guard try FileDigest.sha256(destination).lowercased() == expectedHash.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError.checksumMismatch
        }
        return destination
    }

    private static func trustedReleaseAsset(_ address: String) -> URL? {
        guard let url = URL(string: address), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [ReleaseAsset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
    }

    private struct ReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    private struct AppUpdate {
        let version: String
        let packageName: String
        let packageURL: URL
        let checksumURL: URL
    }
}

enum ReleaseVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = versionParts(candidate), let currentParts = versionParts(current) else { return false }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let withoutPrefix = version.first == "v" ? version.dropFirst() : Substring(version)
        let core = withoutPrefix.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? Substring()
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }
}

private enum UpdateError: LocalizedError {
    case invalidChecksumFile
    case downloadFailed
    case checksumMismatch
    case installerCouldNotOpen

    var errorDescription: String? {
        switch self {
        case .invalidChecksumFile: "The downloaded update has an invalid checksum file. The installer was not opened."
        case .downloadFailed: "The update download did not complete. Try again later."
        case .checksumMismatch: "The update did not match GitHub's published SHA-256 checksum. The installer was removed."
        case .installerCouldNotOpen: "The verified update is downloaded, but macOS Installer could not be opened."
        }
    }
}
