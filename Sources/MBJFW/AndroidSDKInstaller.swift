import CryptoKit
import Foundation

@MainActor
enum AndroidSDKInstaller {
    static func install(
        at root: URL,
        progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void
    ) async throws -> AndroidSDKPaths {
        let paths = AndroidSDKPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.sdkRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.avdHome, withIntermediateDirectories: true)

        progress(.javaRuntime, "Installing the Java runtime…", nil)
        let javaHome = try await installJavaIfNeeded(paths, progress: progress)
        progress(.commandLineTools, "Installing Android command-line tools…", nil)
        try await installCommandToolsIfNeeded(paths, progress: progress)
        progress(.sdkLicenses, "Checking Android SDK licenses…", nil)
        try await runSDKManager(paths, javaHome: javaHome, arguments: ["--licenses"], input: String(repeating: "y\n", count: 20)) { line in
            progress(.sdkLicenses, line, Self.fraction(line))
        }
        progress(.emulatorTools, "Installing the verified Android emulator for \(paths.architecture.displayName)…", nil)
        try await installEmulatorIfNeeded(paths, progress: progress)
        progress(.emulatorTools, "Installing Android platform tools…", nil)
        try await runSDKManager(paths, javaHome: javaHome, arguments: ["--install", "platform-tools"]) { line in
            progress(.emulatorTools, line, Self.fraction(line))
        }
        progress(.systemImage, "Downloading the Android \(paths.architecture.androidABI) system image…", nil)
        try await installSystemImage(paths, progress: progress)
        progress(.device, "Creating your isolated Android device…", nil)
        let avdINI = paths.avdHome.appending(path: "MBJFW.ini")
        if !FileManager.default.fileExists(atPath: avdINI.path) {
            try await AndroidProcessRunner.run(
                paths.avdManager,
                arguments: ["create", "avd", "-n", "MBJFW", "-k", paths.architecture.systemImage, "-d", "pixel_8", "--force"],
                environment: paths.environment(javaHome: javaHome),
                logURL: paths.setupLog,
                input: "no\n"
            )
        }
        try configureAVD(paths)
        return paths
    }

    static func configureAVD(_ paths: AndroidSDKPaths) throws {
        let configURL = paths.avdHome.appending(path: "MBJFW.avd/config.ini")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let defaults = ProfileSettings.default
        let resolution = defaults.guestResolution
        let parts = resolution.split(separator: "x").compactMap { Int($0) }
        let width = parts.first ?? 1280
        let height = parts.dropFirst().first ?? 720
        var values = Dictionary(uniqueKeysWithValues: config.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        })
        values["hw.keyboard"] = "yes"
        values["hw.audioInput"] = "yes"
        values["hw.audioOutput"] = "yes"
        // Keep the established generic resizable profile used by the HWC modes.
        values["hw.device.name"] = "resizable"
        values["hw.device.manufacturer"] = "Android"
        values.removeValue(forKey: "hw.device.hash2")
        values["hw.initialOrientation"] = "landscape"
        values["hw.lcd.width"] = String(width)
        values["hw.lcd.height"] = String(height)
        let density = defaults.guestDensity
        values["hw.lcd.density"] = density
        values["hw.resizable.configs"] = [
            "phone-0-1280-720-\(density)",
            "foldable-1-1600-900-\(density)",
            "tablet-2-1920-1080-\(density)"
        ].joined(separator: ",")
        values["hw.gpu.enabled"] = "yes"
        values["hw.gpu.mode"] = "host"
        values["hw.cpu.ncore"] = String(defaults.guestCores)
        values["hw.ramSize"] = "\(defaults.guestMemory)"
        values["showDeviceFrame"] = "no"
        values["fastboot.forceColdBoot"] = "no"
        values["fastboot.forceFastBoot"] = "yes"
        try values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").appending("\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func installJavaIfNeeded(_ paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws -> URL {
        if let javaHome = paths.javaHome { return javaHome }
        let archive = paths.downloads.appending(path: "temurin-jre21.tar.gz")
        try await download(try remoteURL(paths.architecture.javaRuntimeURL), to: archive, stage: .javaRuntime, paths: paths, progress: progress)
        try FileManager.default.createDirectory(at: paths.jreRoot, withIntermediateDirectories: true)
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", paths.jreRoot.path],
            environment: [:],
            logURL: paths.setupLog
        )
        guard let javaHome = paths.javaHome else { throw AndroidSetupError.javaRuntimeMissing }
        return javaHome
    }

    private static func installCommandToolsIfNeeded(_ paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws {
        guard !FileManager.default.isExecutableFile(atPath: paths.sdkManager.path) else { return }
        let archive = paths.downloads.appending(path: "android-commandlinetools.zip")
        try await download(try remoteURL(paths.architecture.commandToolsURL), to: archive, stage: .commandLineTools, paths: paths, progress: progress)
        progress(.commandLineTools, "Verifying Android command-line tools…", nil)
        let digest = try sha256(archive)
        guard digest == paths.architecture.commandToolsSHA256 else { throw AndroidSetupError.commandToolsChecksumMismatch }
        let staging = paths.downloads.appending(path: "command-tools-unpacked")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", archive.path, "-d", staging.path],
            environment: [:],
            logURL: paths.setupLog
        )
        let latest = paths.sdkRoot.appending(path: "cmdline-tools/latest")
        try FileManager.default.createDirectory(at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: latest.path) {
            try FileManager.default.removeItem(at: latest)
        }
        try FileManager.default.moveItem(at: staging.appending(path: "cmdline-tools"), to: latest)
    }

    private static func installSystemImage(_ paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws {
        let imageDirectory = paths.systemImageDirectory
        let systemImage = imageDirectory.appending(path: "system.img")
        guard !FileManager.default.fileExists(atPath: systemImage.path) else { return }
        try await ensureSystemImageArchive(paths, progress: progress)

        // The archive stores its payload under a top-level ABI directory, so unpack it into the
        // google_apis package root, not into the ABI directory itself. Clear any
        // partial previous unpack (including a stale Android installer marker) first.
        let packageRoot = imageDirectory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: imageDirectory.path) {
            try FileManager.default.removeItem(at: imageDirectory)
        }
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", "-o", paths.systemImageArchive.path, "-d", packageRoot.path],
            environment: [:],
            logURL: paths.setupLog
        )
        guard FileManager.default.fileExists(atPath: systemImage.path) else {
            throw AndroidSetupError.systemImageIncomplete
        }
    }

    private static func installEmulatorIfNeeded(_ paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws {
        if paths.hasExpectedEmulator { return }
        let archive = paths.emulatorArchive
        if FileManager.default.fileExists(atPath: archive.path), !(await archiveIsValid(archive, paths: paths)) {
            try FileManager.default.removeItem(at: archive)
        }
        if !FileManager.default.fileExists(atPath: archive.path) {
            try await download(try remoteURL(paths.architecture.emulatorArchiveURL), to: archive, stage: .emulatorTools, paths: paths, progress: progress)
        }
        progress(.emulatorTools, "Verifying the downloaded emulator archive…", nil)
        guard await archiveIsValid(archive, paths: paths) else {
            try? FileManager.default.removeItem(at: archive)
            throw AndroidSetupError.emulatorArchiveVerificationFailed
        }

        progress(.emulatorTools, "Extracting the pinned emulator runtime…", nil)
        let staging = paths.downloads.appending(path: "emulator-unpacked")
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", "-o", archive.path, "-d", staging.path],
            environment: [:],
            logURL: paths.setupLog
        )
        let stagedEmulator = staging.appending(path: "emulator")
        let revision = try String(contentsOf: stagedEmulator.appending(path: "source.properties"), encoding: .utf8)
        guard revision.contains("Pkg.Revision=\(paths.architecture.emulatorRevision)"),
              revision.contains("Pkg.BuildId=\(paths.architecture.emulatorBuildID)"),
              FileManager.default.isExecutableFile(atPath: stagedEmulator.appending(path: "emulator").path),
              FileManager.default.isExecutableFile(atPath: stagedEmulator.appending(path: "qemu/\(paths.architecture.qemuHostDirectory)/\(paths.architecture.qemuGuestExecutable)").path) else {
            try? FileManager.default.removeItem(at: staging)
            throw AndroidSetupError.emulatorArchiveIncomplete
        }

        let destination = paths.sdkRoot.appending(path: "emulator")
        let previous = paths.downloads.appending(path: "emulator-previous")
        progress(.emulatorTools, "Installing the verified emulator runtime…", nil)
        if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: destination, to: previous) }
        do {
            try FileManager.default.moveItem(at: stagedEmulator, to: destination)
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        } catch {
            if !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: previous.path) {
                try? FileManager.default.moveItem(at: previous, to: destination)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: staging)
    }

    private static func ensureSystemImageArchive(_ paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws {
        let archive = paths.systemImageArchive
        if FileManager.default.fileExists(atPath: archive.path) {
            if await archiveIsValid(archive, paths: paths) { return }
            // A resume gone wrong can leave the file larger than the original (appended ranges),
            // so a corrupt archive is discarded instead of being resumed again.
            try FileManager.default.removeItem(at: archive)
        }
        for _ in 0..<2 {
            try await downloadSystemImage(paths, progress: progress)
            if await archiveIsValid(archive, paths: paths) { return }
            try FileManager.default.removeItem(at: archive)
        }
        throw AndroidSetupError.systemImageVerificationFailed
    }

    private static func downloadSystemImage(_ paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws {
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "-fL", "--show-error", "--retry", "100", "--retry-all-errors",
                "--retry-delay", "3", "--continue-at", "-",
                paths.architecture.systemImageArchiveURL,
                "-o", paths.systemImageArchive.path
            ],
            environment: [:],
            logURL: paths.setupLog,
            progress: { line in
                let transfer = DownloadProgress.curl(line)
                progress(.systemImage, transfer?.detail ?? line, transfer?.fraction ?? Self.fraction(line))
            }
        )
    }

    private static func archiveIsValid(_ archive: URL, paths: AndroidSDKPaths) async -> Bool {
        (try? await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-t", archive.path],
            environment: [:],
            logURL: paths.setupLog
        )) != nil
    }

    private static func runSDKManager(
        _ paths: AndroidSDKPaths,
        javaHome: URL,
        arguments: [String],
        input: String? = nil,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws {
        try await AndroidProcessRunner.run(
            paths.sdkManager,
            arguments: ["--sdk_root=\(paths.sdkRoot.path)"] + arguments,
            environment: paths.environment(javaHome: javaHome),
            logURL: paths.setupLog,
            input: input,
            progress: progress
        )
    }

    private static func download(_ url: URL, to destination: URL, stage: GameLaunchStage, paths: AndroidSDKPaths, progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void) async throws {
        try await AndroidProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-fL", "--retry", "3", "--retry-all-errors", url.absoluteString, "-o", destination.path],
            environment: [:], logURL: paths.setupLog,
            progress: { line in
                let transfer = DownloadProgress.curl(line)
                progress(stage, transfer?.detail ?? line, transfer?.fraction ?? Self.fraction(line))
            }
        )
    }

    private static func fraction(_ text: String) -> Double? {
        let percent = try? NSRegularExpression(pattern: "(?:^|\\s)([0-9]{1,3}(?:\\.[0-9]+)?)%")
        let meter = try? NSRegularExpression(pattern: "^\\s*([0-9]{1,3})\\s+[0-9]+")
        guard let regex = [percent, meter].compactMap({ $0 }).first(where: { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = Double(text[range]) else { return nil }
        return min(1, max(0, value / 100))
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func remoteURL(_ address: String) throws -> URL {
        guard let url = URL(string: address) else { throw AndroidSetupError.downloadURLInvalid }
        return url
    }
}

struct AndroidSDKPaths {
    let root: URL
    let architecture: RuntimeArchitecture
    private let sessionLogDirectory: URL?

    init(root: URL, sessionLogDirectory: URL? = nil, architecture: RuntimeArchitecture = .current) {
        self.root = root
        self.sessionLogDirectory = sessionLogDirectory
        self.architecture = architecture
    }

    var sdkRoot: URL { root.appending(path: "android-sdk") }
    var jreRoot: URL { root.appending(path: "jre") }
    var downloads: URL { root.appending(path: "downloads") }
    var avdHome: URL { root.appending(path: "avd") }
    var emulator: URL { sdkRoot.appending(path: "emulator/emulator") }
    var adb: URL { sdkRoot.appending(path: "platform-tools/adb") }
    var sdkManager: URL { sdkRoot.appending(path: "cmdline-tools/latest/bin/sdkmanager") }
    var avdManager: URL { sdkRoot.appending(path: "cmdline-tools/latest/bin/avdmanager") }
    var emulatorArchive: URL { downloads.appending(path: architecture.emulatorArchiveName) }
    var setupLog: URL { root.appending(path: "setup.log") }
    var launchLog: URL { (sessionLogDirectory ?? root).appending(path: "launch.log") }
    var importLog: URL { root.appending(path: "import.log") }
    var emulatorLog: URL { (sessionLogDirectory ?? root).appending(path: "emulator.log") }
    var systemImageDirectory: URL { sdkRoot.appending(path: architecture.systemImageDirectory) }
    var systemImageArchive: URL { downloads.appending(path: architecture.systemImageArchiveName) }

    var hasExpectedEmulator: Bool {
        guard let revision = try? String(contentsOf: sdkRoot.appending(path: "emulator/source.properties"), encoding: .utf8) else { return false }
        return revision.contains("Pkg.Revision=\(architecture.emulatorRevision)")
            && revision.contains("Pkg.BuildId=\(architecture.emulatorBuildID)")
            && FileManager.default.isExecutableFile(atPath: emulator.path)
            && FileManager.default.isExecutableFile(atPath: sdkRoot.appending(path: "emulator/qemu/\(architecture.qemuHostDirectory)/\(architecture.qemuGuestExecutable)").path)
    }

    var isReady: Bool {
        hasExpectedEmulator
            && FileManager.default.isExecutableFile(atPath: adb.path)
            && FileManager.default.fileExists(atPath: systemImageDirectory.appending(path: "system.img").path)
            && FileManager.default.fileExists(atPath: avdHome.appending(path: "MBJFW.ini").path)
    }

    var javaHome: URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: jreRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents
            .map { $0.appending(path: "Contents/Home") }
            .first { FileManager.default.isExecutableFile(atPath: $0.appending(path: "bin/java").path) }
    }

    func environment(javaHome: URL?) -> [String: String] {
        var values = [
            "ANDROID_HOME": sdkRoot.path,
            "ANDROID_SDK_ROOT": sdkRoot.path,
            "ANDROID_AVD_HOME": avdHome.path
        ]
        if let javaHome { values["JAVA_HOME"] = javaHome.path }
        return values
    }
}

enum AndroidSetupError: LocalizedError {
    case javaRuntimeMissing
    case commandToolsChecksumMismatch
    case downloadURLInvalid
    case systemImageIncomplete
    case systemImageVerificationFailed
    case emulatorArchiveIncomplete
    case emulatorArchiveVerificationFailed
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .javaRuntimeMissing:
            "The downloaded Java runtime could not be found."
        case .commandToolsChecksumMismatch:
            "The Android command-line tools failed their SHA-256 integrity check."
        case .downloadURLInvalid:
            "An Android runtime download address is invalid."
        case .systemImageIncomplete:
            "The Android system image download did not contain system.img."
        case .systemImageVerificationFailed:
            "The Android system image download failed its integrity check. Check your internet connection and try again."
        case .emulatorArchiveIncomplete:
            "The Android Emulator archive did not contain the verified host runtime and guest binary. Your profile data was preserved."
        case .emulatorArchiveVerificationFailed:
            "The Android Emulator download failed archive verification. Check your connection and try again."
        case let .downloadFailed(url):
            "The download failed: \(url)"
        }
    }
}
