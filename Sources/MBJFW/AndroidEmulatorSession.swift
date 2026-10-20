import Foundation
import SwiftUI
import CryptoKit
import Observation
import MBJFWFrameBridge
import Darwin

@MainActor
@Observable
final class AndroidEmulatorSession {
    private var process: Process?
    private var emulatorLogHandle: FileHandle?
    private var activeAccountID: UUID?
    private var activeSerial: String?
    private var nativeSession: MBJFWNativeSession?
    private var nativeSessionName: String?
    private var reservedPort: Int?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var onProcessExit: (() -> Void)?
    var serial: String? { activeSerial }

    var nativeStatus: MBJFWNativeStatus? {
        guard let nativeSession else { return nil }
        var status = MBJFWNativeStatus()
        return mbjfw_native_session_read(nativeSession, &status) != 0 ? status : nil
    }

    func focusGameWindow() {
        if let nativeSession { mbjfw_native_session_command(nativeSession, UInt32(MBJFWNativeShow.rawValue)) }
    }

    func setNativeGeometry(width: Int, height: Int) {
        if let nativeSession { mbjfw_native_session_geometry(nativeSession, UInt32(width), UInt32(height)) }
    }

    func setNativeCaptureRequest(_ requested: Bool) {
        if let nativeSession { mbjfw_native_session_capture_request(nativeSession, requested ? 1 : 0) }
    }

    func setNativeDisplayFollowsWindow(_ followsWindow: Bool) {
        if let nativeSession { mbjfw_native_session_display_follows_window(nativeSession, followsWindow ? 1 : 0) }
    }

    func showNativeNotice(_ message: String, kind: UInt32 = 0, durationMilliseconds: UInt32 = 5000) {
        guard let nativeSession else { return }
        message.withCString { mbjfw_native_session_notice(nativeSession, $0, kind, durationMilliseconds) }
    }

    func launch(
        apk: URL,
        account: PlayerAccount,
        dataDirectory: URL,
        settings: ProfileSettings,
        paths: AndroidSDKPaths,
        progress: @MainActor (GameLaunchStage, String) -> Void
    ) async throws {
        if activeAccountID != account.id { await stop(paths: paths) }
        let adb = paths.adb
        var serial = activeSerial
        if process == nil {
            progress(.startingAndroid, "Starting the Android device…")
            let profileRegistry = try await ProfileDevice.prepare(account: account, directory: dataDirectory, settings: settings, paths: paths)
            let receipt = dataDirectory.appending(path: "installed-minecraft.json")
            if let oldData = try? Data(contentsOf: receipt),
               let old = try? JSONDecoder().decode(InstalledGameReceipt.self, from: oldData) {
                let newHash = try await Task.detached { try FileDigest.sha256(apk) }.value
                if old.sha256 != newHash {
                    progress(.startingAndroid, "Backing up this profile before changing Minecraft…")
                    _ = try await ProfileBackupStore.create(account: account, source: dataDirectory)
                }
            }
            try await AndroidProcessRunner.run(
                adb,
                arguments: ["start-server"],
                environment: paths.environment(javaHome: paths.javaHome),
                logURL: paths.launchLog
            )
            let devices = try await AndroidProcessRunner.run(
                adb,
                arguments: ["devices"],
                environment: paths.environment(javaHome: paths.javaHome),
                logURL: paths.launchLog
            )
            let port = try Self.availablePort(in: devices)
            reservedPort = port
            serial = "emulator-\(port)"
            if let nativeSession {
                mbjfw_native_session_destroy(nativeSession, nativeSessionName)
                self.nativeSession = nil
            }
            let busName = "mbjfw-n-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
            let dimensions = settings.guestResolution.split(separator: "x").compactMap { UInt32($0) }
            nativeSession = busName.withCString { mbjfw_native_session_create($0, dimensions.first ?? 1280, dimensions.dropFirst().first ?? 720) }
            guard nativeSession != nil else { throw AndroidEmulatorError.nativeDisplayUnavailable }
            mbjfw_native_session_display_follows_window(nativeSession, settings.displayFollowsWindow ? 1 : 0)
            nativeSessionName = busName
            let emulator = Process()
            emulator.executableURL = try NativeRuntimeBundle.prepare(paths: paths)
            let graphicsMode = settings.graphicsMode
            var arguments = [
                "-avd", "MBJFW",
                "-datadir", dataDirectory.path,
                "-port", "\(port)",
                "-gpu", graphicsMode == "software" ? "swangle" : "host",
                "-feature", "Vulkan,GuestAngle,VirtioInput,VirtioMouse,VirtioDualModeMouse,HWCMultiConfigs,-SupportPixelFold,-DeviceSkinOverlay",
                "-no-boot-anim",
                "-no-snapshot",
                "-memory", "\(settings.guestMemory)",
                "-cores", "\(settings.guestCores)"
            ]
            // Keep the native renderer, suppress the stock Qt window.
            arguments.append("-qt-hide-window")
            arguments.append("-no-metrics")
            if settings.disableGameAudio { arguments.append("-no-audio") }
            emulator.arguments = arguments
            var environment = Self.processEnvironment(paths)
            environment.merge(NativeRuntimeBundle.environment(paths: paths)) { _, value in value }
            environment["ANDROID_AVD_HOME"] = profileRegistry.path
            environment["MBJFW_NATIVE_SESSION"] = busName
            environment["MBJFW_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment["MBJFW_ADB_PATH"] = paths.adb.path
            environment["MBJFW_DEVICE_SERIAL"] = serial
            guard let bridgePath = mbjfw_native_host_library_path().map(String.init(cString:)) else {
                throw AndroidEmulatorError.nativeDisplayUnavailable
            }
            environment["DYLD_INSERT_LIBRARIES"] = bridgePath
            emulator.environment = environment
            emulator.currentDirectoryURL = paths.emulator.deletingLastPathComponent()
            let logHandle = try Self.createEmulatorLog(paths.emulatorLog)
            emulator.standardOutput = logHandle
            emulator.standardError = logHandle
            emulator.terminationHandler = { [weak self] completed in
                let identifier = completed.processIdentifier
                Task { @MainActor [weak self] in self?.processDidExit(identifier) }
            }
            try emulator.run()
            process = emulator
            emulatorLogHandle = logHandle
            activeAccountID = account.id
            activeSerial = serial
            progress(.bootingAndroid, "Waiting for Android to finish starting…")
            try await waitForBoot(serial: serial ?? "emulator-5580", paths: paths) { elapsed in
                progress(.bootingAndroid, "Waiting for Android to finish starting… (\(elapsed)s)")
            }
            try await verifyGuestArchitecture(serial: serial ?? "emulator-5580", paths: paths)
        }

        guard let serial else { throw AndroidEmulatorError.deviceNotReady }
        // An older recovery HOME may auto-open Minecraft during boot. Stop that
        // instance before input, overlays or density can destroy its first surface.
        try await AndroidProcessRunner.run(adb, arguments: ["-s", serial, "shell", "am", "force-stop", "com.mojang.minecraftpe"], environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
        guard let hid = PackagedResourceLocator.url(forResource: paths.architecture.hidResourceName) else {
            throw AndroidEmulatorError.nativeDisplayUnavailable
        }
        progress(.provisioningDevice, "Connecting the HID keyboard and mouse…")
        try await AndroidProcessRunner.run(adb, arguments: ["-s", serial, "push", hid.path, "/data/local/tmp/mbjfw-hid"], environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
        try await AndroidProcessRunner.run(adb, arguments: ["-s", serial, "shell", "chmod", "755", "/data/local/tmp/mbjfw-hid"], environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
        if let nativeSession { mbjfw_native_session_command(nativeSession, UInt32(MBJFWNativePrepareInput.rawValue)) }
        var inputReady = false
        for _ in 0..<100 {
            try Task.checkCancellation()
            if nativeStatus?.state == MBJFWNativeFailed.rawValue { break }
            if nativeStatus?.state == MBJFWNativeInputReady.rawValue { inputReady = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard inputReady else { throw AndroidEmulatorError.nativeDisplayUnavailable }
        progress(.provisioningDevice, "Trimming optional Android apps for Minecraft…")
        let disabledApps = try await AndroidAppliancePolicy.apply(serial: serial, dataDirectory: dataDirectory, paths: paths)
        progress(.provisioningDevice, "Android appliance ready · \(disabledApps) optional apps disabled.")
        let display = settings.guestResolution.split(separator: "x").compactMap { Int($0) }
        if display.count == 2 {
            // Remove a logical override left by an older build. The AVD's
            // configured HWC mode now owns the physical guest resolution.
            try await AndroidProcessRunner.run(adb, arguments: ["-s", serial, "shell", "wm", "size", "reset"], environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
            try await AndroidProcessRunner.run(adb, arguments: ["-s", serial, "shell", "wm", "density", settings.guestDensity], environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
        }
        let apkHash = try Self.sha256(apk)
        let receiptURL = dataDirectory.appending(path: "installed-minecraft.json")
        let installedPath = try? await AndroidProcessRunner.run(adb, arguments: ["-s", serial, "shell", "pm", "path", "com.mojang.minecraftpe"], environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
        let installedHash = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(InstalledGameReceipt.self, from: $0).sha256 }
        if installedHash != apkHash || installedPath?.contains("package:") != true {
            progress(.installingGame, "Installing Minecraft  ·  \(apkHash.prefix(12))")
            do {
                try await AndroidProcessRunner.run(
                    adb,
                    arguments: ["-s", serial, "install", "-r", apk.path],
                    environment: paths.environment(javaHome: paths.javaHome),
                    logURL: paths.launchLog
                )
                let receipt = try JSONEncoder().encode(InstalledGameReceipt(sha256: apkHash, installedAt: .now))
                try receipt.write(to: receiptURL, options: .atomic)
            } catch {
                throw AndroidEmulatorError.gameInstallFailed(error.localizedDescription)
            }
        } else {
            progress(.installingGame, "Minecraft is already installed; keeping its saved data.")
        }
        progress(.launchingGame, "Launching Bedrock…")
        try await AndroidAppliancePolicy.provisionKiosk(serial: serial, dataDirectory: dataDirectory, paths: paths)
        let activity = await resolveLauncherActivity(serial: serial, paths: paths)
        try await waitForGameForeground(serial: serial, activity: activity, paths: paths)
        progress(.display, "Opening the native GPU game window…")
        focusGameWindow()
        for _ in 0..<900 {
            try Task.checkCancellation()
            guard process?.isRunning == true else { throw AndroidEmulatorError.deviceNotReady }
            if let status = nativeStatus {
                if status.state == MBJFWNativeWindowReady.rawValue { progress(.display, "Native game window ready."); return }
                if status.state == MBJFWNativeFailed.rawValue { throw AndroidEmulatorError.nativeDisplayUnavailable }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AndroidEmulatorError.nativeDisplayUnavailable
    }

    func restoreGameForeground(paths: AndroidSDKPaths) async throws -> Bool {
        guard let serial = activeSerial else { throw AndroidEmulatorError.deviceNotReady }
        let state = try await AndroidProcessRunner.run(
            paths.adb,
            arguments: ["-s", serial, "shell", "dumpsys activity activities | grep topResumedActivity"],
            environment: paths.environment(javaHome: paths.javaHome),
            logURL: paths.launchLog
        )
        let foreground = state.split(whereSeparator: \.isNewline).first { $0.contains("topResumedActivity=") }
        guard foreground?.contains("com.mojang.minecraftpe/") != true else { return false }
        // Let game-owned authentication and runtime permission activities finish.
        let allowed = ["com.android.chrome/", "com.google.android.permissioncontroller/", "com.android.permissioncontroller/", "com.google.android.gms/"]
        if allowed.contains(where: { foreground?.contains($0) == true }) { return false }
        let component = await resolveLauncherActivity(serial: serial, paths: paths)
        _ = try await AndroidProcessRunner.run(
            paths.adb,
            arguments: ["-s", serial, "shell", "am", "start", "-n", component],
            environment: paths.environment(javaHome: paths.javaHome),
            logURL: paths.launchLog
        )
        return true
    }

    private func waitForGameForeground(serial: String, activity: String, paths: AndroidSDKPaths) async throws {
        for attempt in 0..<90 {
            try Task.checkCancellation()
            let state = try await AndroidProcessRunner.run(
                paths.adb,
                arguments: ["-s", serial, "shell", "dumpsys activity activities | grep topResumedActivity"],
                environment: paths.environment(javaHome: paths.javaHome),
                logURL: paths.launchLog
            )
            let foreground = state.split(whereSeparator: \.isNewline).first { $0.contains("topResumedActivity=") }
            if foreground?.contains("com.mojang.minecraftpe/") == true { return }
            if attempt > 0, attempt.isMultiple(of: 10) {
                _ = try await AndroidProcessRunner.run(
                    paths.adb,
                    arguments: ["-s", serial, "shell", "am", "start", "-n", activity],
                    environment: paths.environment(javaHome: paths.javaHome),
                    logURL: paths.launchLog
                )
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AndroidEmulatorError.gameLaunchTimedOut
    }

    func stop(paths: AndroidSDKPaths) async {
        if let nativeSession { mbjfw_native_session_command(nativeSession, UInt32(MBJFWNativeReleaseInput.rawValue)) }
        guard let process else { releaseNativeSession(); releaseReservedPort(); return }
        if let activeSerial {
            do {
                _ = try await AndroidProcessRunner.run(
                    paths.adb,
                    arguments: ["-s", activeSerial, "emu", "kill"],
                    environment: paths.environment(javaHome: paths.javaHome),
                    logURL: paths.launchLog
                )
            } catch {
                process.terminate()
            }
        } else {
            process.terminate()
        }
        let identifier = process.processIdentifier
        let shutdownDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.process?.processIdentifier == identifier, process.isRunning else { return }
            kill(identifier, SIGKILL)
        }
        await withCheckedContinuation { continuation in
            if !process.isRunning { continuation.resume() }
            else { terminationWaiters.append(continuation) }
        }
        shutdownDeadline.cancel()
    }

    private func waitForBoot(serial: String, paths: AndroidSDKPaths, progress: @MainActor (Int) -> Void) async throws {
        for elapsed in 0..<120 {
            try Task.checkCancellation()
            guard process?.isRunning == true else { throw AndroidEmulatorError.deviceNotReady }
            let result = try? await AndroidProcessRunner.run(
                paths.adb,
                arguments: ["-s", serial, "shell", "getprop", "sys.boot_completed"],
                environment: paths.environment(javaHome: paths.javaHome),
                logURL: paths.launchLog
            )
            if result?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            progress(elapsed + 1)
            try await Task.sleep(for: .seconds(1))
        }
        throw AndroidEmulatorError.bootTimedOut
    }

    private func verifyGuestArchitecture(serial: String, paths: AndroidSDKPaths) async throws {
        guard paths.architecture == .x86_64 else { return }
        let environment = paths.environment(javaHome: paths.javaHome)
        let nativeBridge = try await AndroidProcessRunner.run(
            paths.adb,
            arguments: ["-s", serial, "shell", "getprop", "ro.dalvik.vm.native.bridge"],
            environment: environment,
            logURL: paths.launchLog
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let translationLibrary = try? await AndroidProcessRunner.run(
            paths.adb,
            arguments: ["-s", serial, "shell", "test", "-f", "/system/lib64/libndk_translation.so"],
            environment: environment,
            logURL: paths.launchLog
        )
        guard nativeBridge == "libndk_translation.so", translationLibrary != nil else {
            throw AndroidEmulatorError.armTranslationUnavailable
        }
    }

    private func resolveLauncherActivity(serial: String, paths: AndroidSDKPaths) async -> String {
        let fallback = "com.mojang.minecraftpe/.MainActivity"
        guard let output = try? await AndroidProcessRunner.run(
            paths.adb,
            arguments: [
                "-s", serial, "shell", "cmd", "package", "resolve-activity", "--brief",
                "-c", "android.intent.category.LAUNCHER", "com.mojang.minecraftpe"
            ],
            environment: paths.environment(javaHome: paths.javaHome),
            logURL: paths.launchLog
        ) else { return fallback }
        let component = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.contains("/") && !$0.contains(" ") }
        return component ?? fallback
    }

    private func processDidExit(_ identifier: Int32) {
        guard process?.processIdentifier == identifier else { return }
        process = nil
        activeAccountID = nil
        activeSerial = nil
        releaseNativeSession()
        releaseReservedPort()
        try? emulatorLogHandle?.close()
        emulatorLogHandle = nil
        terminationWaiters.forEach { $0.resume() }
        terminationWaiters.removeAll()
        onProcessExit?()
    }

    private func releaseNativeSession() {
        if let nativeSession { mbjfw_native_session_destroy(nativeSession, nativeSessionName) }
        nativeSession = nil
        nativeSessionName = nil
    }

    private func releaseReservedPort() {
        guard let reservedPort else { return }
        Self.leasedPorts.remove(reservedPort)
        self.reservedPort = nil
    }

    private static var leasedPorts = Set<Int>()

    private static func availablePort(in devices: String) throws -> Int {
        let usedPorts = devices.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("emulator-") else { return nil }
            return Int(line.dropFirst("emulator-".count).prefix(4))
        }
        guard let port = stride(from: 5580, through: 5680, by: 2)
            .first(where: { !usedPorts.contains($0) && !leasedPorts.contains($0) }) else {
            throw AndroidEmulatorError.emulatorSlotsExhausted
        }
        leasedPorts.insert(port)
        return port
    }

    private static func processEnvironment(_ paths: AndroidSDKPaths) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        values.merge(paths.environment(javaHome: paths.javaHome)) { _, newValue in newValue }
        return values
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func createEmulatorLog(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

enum AndroidEmulatorError: LocalizedError {
    case deviceNotReady
    case bootTimedOut
    case controlChannelUnavailable
    case gameLaunchTimedOut
    case nativeDisplayUnavailable
    case armTranslationUnavailable
    case emulatorSlotsExhausted
    case gameInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotReady:
            "The Android device did not start. Try launching Bedrock again."
        case .bootTimedOut:
            "Android did not finish starting. Check the emulator log in \(NSHomeDirectory())/Library/Application Support/MBJFW/\(RuntimeArchitecture.current.runtimeRootDirectoryName)/emulator.log."
        case .controlChannelUnavailable:
            "The Android device started but its control channel did not respond. Check emulator.log."
        case .gameLaunchTimedOut:
            "Minecraft did not reach the foreground. Android is still running; try again or check launch.log."
        case .nativeDisplayUnavailable:
            "The native game window or HID devices did not become ready. Your profile is preserved. Check emulator.log for details."
        case .armTranslationUnavailable:
            "This Intel Android image does not expose Android's ARM64 app translation layer. Minecraft needs that layer to run on Intel; reinstall the Android runtime and try again."
        case .emulatorSlotsExhausted:
            "All Android Emulator slots from 5580 through 5680 are in use. Stop an open profile and try again."
        case let .gameInstallFailed(message):
            "Minecraft could not be updated without changing your profile data: \(message)"
        }
    }
}

private struct InstalledGameReceipt: Codable {
    let sha256: String
    let installedAt: Date
}
