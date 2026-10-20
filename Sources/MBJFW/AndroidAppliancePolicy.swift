import Foundation
import CryptoKit

@MainActor
enum AndroidAppliancePolicy {
    static let optionalPackages: Set<String> = [
        "com.google.android.gm", "com.google.android.apps.maps", "com.google.android.apps.photos",
        "com.google.android.apps.docs", "com.google.android.youtube", "com.google.android.apps.youtube.music",
        "com.google.android.googlequicksearchbox", "com.google.android.apps.wellbeing", "com.google.android.calendar",
        "com.google.android.contacts", "com.google.android.dialer", "com.google.android.apps.messaging",
        "com.google.android.deskclock", "com.android.camera2", "com.android.cameraextensions",
        "com.android.printspooler", "com.android.bips", "com.google.android.printservice.recommendation",
        "com.google.android.projection.gearhead", "com.google.android.feedback", "com.google.android.apps.wallpaper",
        "com.google.android.apps.wallpaper.nexus", "com.android.wallpaper.livepicker", "com.android.wallpapercropper",
        "com.android.egg", "com.android.dreams.basic", "com.google.android.tag",
        "com.google.android.healthconnect.controller", "com.google.android.health.connect.backuprestore",
        "com.google.android.apps.safetyhub", "com.google.android.apps.restore", "com.google.android.markup",
        "com.android.DeviceAsWebcam", "com.android.devicediagnostics", "com.android.traceur",
        "com.google.android.adservices.api", "com.google.android.ondevicepersonalization.services",
        "com.google.android.federatedcompute", "com.android.devicelockcontroller",
        "com.google.android.gms.supervision", "com.android.nfc",
        "com.google.android.as", "com.google.android.as.oss", "com.android.vending"
    ]

    static func apply(serial: String, dataDirectory: URL, paths: AndroidSDKPaths) async throws -> AndroidApplianceResult {
        try await configureDesktopSession(serial: serial, paths: paths)
        try await removePhoneDisplayDecorations(serial: serial, paths: paths)
        let manifestURL = dataDirectory.appending(path: "android-app-policy.json")
        let fingerprint = try await command(paths, serial, ["shell", "getprop", "ro.build.fingerprint"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(PolicyManifest.self, from: $0) }

        let installedText = try await command(paths, serial, ["shell", "pm", "list", "packages", "--user", "0"])
        let installed = Set(installedText.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: ":").last.map(String.init) })
        let disabledText = try await command(paths, serial, ["shell", "pm", "list", "packages", "-d", "--user", "0"])
        let alreadyDisabled = Set(disabledText.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: ":").last.map(String.init) })
        var changed = previous?.disabledPackages ?? []
        var skipped: [String] = []
        let pendingPackages = optionalPackages.sorted().filter { installed.contains($0) && !alreadyDisabled.contains($0) }
        for (index, package) in pendingPackages.enumerated() {
            do {
                let result = try await disableOptionalPackage(package, serial: serial, paths: paths)
                if result.contains("disabled-user") { changed.append(package) }
            } catch {
                skipped.append(package)
                // These packages are optional. A failed disable means Android
                // is not in a reliable state for more Package Manager calls;
                // leave the rest enabled and let the game continue provisioning.
                skipped.append(contentsOf: pendingPackages.dropFirst(index + 1))
                break
            }
        }
        let priorPolicy: String
        if let savedPolicy = previous?.previousPolicyControl {
            priorPolicy = savedPolicy
        } else {
            priorPolicy = try await command(paths, serial, ["shell", "settings", "get", "global", "policy_control"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await setImmersiveMode(serial: serial, paths: paths)
        let manifest = PolicyManifest(version: 3, fingerprint: fingerprint, disabledPackages: Array(Set(changed)).sorted(), previousPolicyControl: priorPolicy == "null" ? nil : priorPolicy)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return AndroidApplianceResult(
            disabledPackages: changed.count + alreadyDisabled.intersection(optionalPackages).count,
            skippedPackages: skipped
        )
    }

    static func restore(serial: String, dataDirectory: URL, paths: AndroidSDKPaths) async throws -> Int {
        let manifestURL = dataDirectory.appending(path: "android-app-policy.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PolicyManifest.self, from: data) else { return 0 }
        let installedText = try await command(paths, serial, ["shell", "pm", "list", "packages", "--user", "0"])
        let installed = Set(installedText.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: ":").last.map(String.init) })
        var restored = 0
        for package in manifest.disabledPackages where installed.contains(package) {
            let result = try await command(paths, serial, ["shell", "pm", "enable", "--user", "0", package])
            if result.contains("new state: enabled") { restored += 1 }
        }
        if let previousPolicyControl = manifest.previousPolicyControl {
            _ = try? await command(paths, serial, ["shell", "settings", "put", "global", "policy_control", previousPolicyControl])
        } else {
            _ = try? await command(paths, serial, ["shell", "settings", "delete", "global", "policy_control"])
        }
        try FileManager.default.removeItem(at: manifestURL)
        return restored
    }

    static func provisionKiosk(serial: String, dataDirectory: URL, paths: AndroidSDKPaths) async throws {
        try await waitForPackageService(serial: serial, paths: paths)
        guard let apk = PackagedResourceLocator.url(forResource: "appliance", withExtension: "apk") else {
            throw AndroidEmulatorError.nativeDisplayUnavailable
        }
        let digest = SHA256.hash(data: try Data(contentsOf: apk)).map { String(format: "%02x", $0) }.joined()
        let receipt = dataDirectory.appending(path: "appliance-version.txt")
        let installed = (try? await command(paths, serial, ["shell", "pm", "path", "dev.mbjfw.appliance"])) ?? ""
        if (try? String(contentsOf: receipt, encoding: .utf8)) != digest || !installed.contains("package:") {
            _ = try await installAPK(apk, serial: serial, paths: paths, testOnly: true) { _ in }
            try digest.write(to: receipt, atomically: true, encoding: .utf8)
        }
        var owners = try await command(paths, serial, ["shell", "dpm", "list-owners"])
        if !owners.contains("dev.mbjfw.appliance/.AdminReceiver,DeviceOwner") {
            _ = try await command(paths, serial, ["shell", "dpm", "set-device-owner", "dev.mbjfw.appliance/.AdminReceiver"])
            owners = try await command(paths, serial, ["shell", "dpm", "list-owners"])
        }
        guard owners.contains("dev.mbjfw.appliance/.AdminReceiver,DeviceOwner") else {
            throw AndroidApplianceError.ownerUnavailable
        }
        _ = try await command(paths, serial, ["shell", "am", "start", "-W", "-n", "dev.mbjfw.appliance/.HomeActivity", "--ez", "hostReady", "true"])
        let home = try await command(paths, serial, ["shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME"])
        guard home.contains("dev.mbjfw.appliance/") else { throw AndroidApplianceError.homeUnavailable }
        try await configureDesktopSession(serial: serial, paths: paths)
        // A verified, persistent recovery HOME must exist before removing launchers.
        let installedPackages = try await command(paths, serial, ["shell", "pm", "list", "packages", "--user", "0"])
        for package in ["com.google.android.apps.nexuslauncher", "com.android.launcher3", "com.android.launcher"] {
            if installedPackages.split(whereSeparator: \.isNewline).contains("package:\(package)") {
                _ = try await command(paths, serial, ["shell", "pm", "disable-user", "--user", "0", package])
            }
        }
    }

    /// Older appliance policies disabled Play Store along with ordinary apps.
    /// Android's package-verification path can depend on the verifier being
    /// enabled while a sideload is being committed, so restore it before any
    /// Minecraft install or update. `apply` can trim it again after success.
    static func preparePackageInstaller(serial: String, paths: AndroidSDKPaths) async throws -> Bool {
        try await waitForPackageService(serial: serial, paths: paths, stableFor: .seconds(2))
        let disabled = try await command(paths, serial, ["shell", "pm", "list", "packages", "-d", "--user", "0"])
        guard disabledPackageNames(in: disabled).contains("com.android.vending") else { return false }
        _ = try await command(paths, serial, ["shell", "pm", "enable", "--user", "0", "com.android.vending"])
        try await waitForPackageService(serial: serial, paths: paths, stableFor: .seconds(2))
        return true
    }

    private static func setImmersiveMode(serial: String, paths: AndroidSDKPaths) async throws {
        _ = try await command(paths, serial, ["shell", "settings", "put", "global", "policy_control", "immersive.full=*"])
    }

    private static func configureDesktopSession(serial: String, paths: AndroidSDKPaths) async throws {
        for setting in [
            ["secure", "show_ime_with_hard_keyboard", "0"],
            ["secure", "lockscreen.disabled", "1"],
            ["secure", "sleep_timeout", "-1"],
            ["secure", "screensaver_enabled", "0"],
            ["system", "screen_off_timeout", "2147483647"],
            ["global", "stay_on_while_plugged_in", "7"]
        ] {
            _ = try await command(paths, serial, ["shell", "settings", "put"] + setting)
        }
        _ = try await command(paths, serial, ["shell", "svc", "power", "stayon", "true"])
        _ = try await command(paths, serial, ["emu", "power", "ac", "on"])
        _ = try await command(paths, serial, ["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        _ = try await command(paths, serial, ["shell", "wm", "dismiss-keyguard"])
    }

    private static func removePhoneDisplayDecorations(serial: String, paths: AndroidSDKPaths) async throws {
        // Device-frame flags only affect Qt. Android's Pixel overlays independently
        // draw rounded corners and a camera hole into the composed guest framebuffer.
        let overlays = try await command(paths, serial, ["shell", "cmd", "overlay", "list", "--user", "0"])
        var changed = false
        for line in overlays.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0] == "[x]" else { continue }
            let name = String(fields[1])
            if name.hasPrefix("com.android.internal.emulation.pixel_") ||
                name.hasPrefix("com.android.systemui.emulation.pixel_") ||
                name.hasPrefix("com.android.internal.display.cutout.emulation.") {
                _ = try await command(paths, serial, ["shell", "cmd", "overlay", "disable", "--user", "0", name])
                changed = true
            }
        }
        if changed {
            // ScreenDecorations caches its corner drawables across overlay
            // changes. Restart this persistent component before Minecraft starts.
            _ = try await command(paths, serial, ["shell", "am", "crash", "com.android.systemui"])
            try await Task.sleep(for: .seconds(1))
            _ = try await command(paths, serial, ["shell", "wm", "dismiss-keyguard"])
        }
    }

    private static func command(_ paths: AndroidSDKPaths, _ serial: String, _ arguments: [String], timeout: Duration? = nil) async throws -> String {
        try await AndroidProcessRunner.run(paths.adb, arguments: ["-s", serial] + arguments, environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog, timeout: timeout)
    }

    private static func disableOptionalPackage(_ package: String, serial: String, paths: AndroidSDKPaths) async throws -> String {
        for attempt in 0..<3 {
            do {
                return try await command(paths, serial, ["shell", "pm", "disable-user", "--user", "0", package])
            } catch {
                guard isTransientPackageServiceFailure(error), attempt < 2 else { throw error }
                try await waitForPackageService(serial: serial, paths: paths)
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw AndroidCommandError(command: "pm disable-user \(package)", status: -1, output: "Package Manager did not recover.")
    }

    private static func waitForPackageService(
        serial: String,
        paths: AndroidSDKPaths,
        stableFor: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        var healthySince: ContinuousClock.Instant?
        var lastFailure = "Package Manager service is unavailable."
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let status = try await command(paths, serial, ["shell", "service", "check", "package"], timeout: .seconds(3))
                guard status.contains("Service package: found") else {
                    healthySince = nil
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                // `service check` only proves that the binder name exists. Keep
                // probing a real Package Manager transaction until it has stayed
                // healthy; two quick checks raced system_server restarts during APK
                // installation on profiles created by earlier builds.
                let probe = try await command(paths, serial, ["shell", "pm", "path", "android"], timeout: .seconds(4))
                if probe.contains("package:") {
                    if healthySince == nil { healthySince = .now }
                    if let healthySince, healthySince.duration(to: .now) >= stableFor { return }
                } else {
                    healthySince = nil
                    lastFailure = "Package Manager did not return the framework package path."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                healthySince = nil
                lastFailure = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        throw AndroidCommandError(
            command: "wait for Android Package Manager",
            status: -1,
            output: "Package Manager did not recover within 25 seconds. Last check: \(lastFailure)"
        )
    }

    @discardableResult
    static func installAPK(
        _ apk: URL,
        serial: String,
        paths: AndroidSDKPaths,
        testOnly: Bool = false,
        progress: @MainActor (String) -> Void
    ) async throws -> String {
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                progress("Android Package Manager restarted; waiting for a stable recovery before retry \(attempt + 1)/3…")
                try await waitForPackageService(serial: serial, paths: paths, stableFor: .seconds(8))
            }

            let arguments = installArguments(apkPath: apk.path, attempt: attempt, testOnly: testOnly)
            do {
                return try await command(paths, serial, arguments)
            } catch {
                await captureInstallDiagnostics(serial: serial, paths: paths)
                guard isTransientPackageServiceFailure(error), attempt < 2 else { throw error }
                lastError = error
            }
        }
        throw lastError ?? AndroidCommandError(
            command: "install \(apk.lastPathComponent)",
            status: -1,
            output: "Android Package Manager stopped responding during APK installation."
        )
    }

    static func installArguments(apkPath: String, attempt: Int, testOnly: Bool) -> [String] {
        var arguments = ["install", "-r"]
        if testOnly { arguments.append("-t") }
        // ADB's streamed install keeps the APK transfer and Package Manager
        // session coupled. After a Package Manager disconnect, push the file
        // first and invoke Package Manager as a separate operation.
        if attempt > 0 { arguments.append("--no-streaming") }
        arguments.append(apkPath)
        return arguments
    }

    static func isTransientPackageServiceFailure(_ error: Error) -> Bool {
        guard let commandError = error as? AndroidCommandError else { return false }
        let details = "\(commandError.command)\n\(commandError.output)".lowercased()
        return details.contains("failure calling service package: broken pipe") ||
            details.contains("failure calling service package: dead object") ||
            details.contains("can't find service: package")
    }

    static func disabledPackageNames(in output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            return String(line.dropFirst("package:".count))
        })
    }

    private static func captureInstallDiagnostics(serial: String, paths: AndroidSDKPaths) async {
        // logcat's crash buffer survives system_server restarts and is the best
        // source for the Java exception behind a broken Package Manager binder.
        _ = try? await command(paths, serial, ["logcat", "-b", "crash", "-d", "-v", "brief", "-t", "200"])
        _ = try? await command(paths, serial, ["logcat", "-b", "events", "-d", "-v", "brief", "-t", "300"])
        _ = try? await command(paths, serial, ["shell", "df", "-h", "/data"], timeout: .seconds(4))
        _ = try? await command(paths, serial, ["shell", "cat", "/proc/meminfo"], timeout: .seconds(4))
    }
}

struct AndroidApplianceResult: Equatable {
    let disabledPackages: Int
    let skippedPackages: [String]

    var progressDetail: String {
        guard !skippedPackages.isEmpty else {
            return "Android appliance ready · \(disabledPackages) optional apps disabled."
        }
        let examples = skippedPackages.prefix(3).joined(separator: ", ")
        let remainder = skippedPackages.count > 3 ? " and \(skippedPackages.count - 3) more" : ""
        return "Android appliance ready · \(disabledPackages) optional apps disabled. Some optional apps remain enabled: \(examples)\(remainder)."
    }
}

private enum AndroidApplianceError: LocalizedError {
    case ownerUnavailable, homeUnavailable
    var errorDescription: String? {
        switch self {
        case .ownerUnavailable: "Android could not enable Minecraft lock task. Your profile is preserved; check launch.log before repairing this device."
        case .homeUnavailable: "The Minecraft recovery activity could not become Android's home. The existing launcher was retained."
        }
    }
}

private struct PolicyManifest: Codable {
    let version: Int
    let fingerprint: String
    let disabledPackages: [String]
    let previousPolicyControl: String?
}
