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

    static func apply(serial: String, dataDirectory: URL, paths: AndroidSDKPaths) async throws -> Int {
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
        for package in optionalPackages.sorted() where installed.contains(package) && !alreadyDisabled.contains(package) {
            let result = try await command(paths, serial, ["shell", "pm", "disable-user", "--user", "0", package])
            if result.contains("disabled-user") { changed.append(package) }
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
        return changed.count + alreadyDisabled.intersection(optionalPackages).count
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
        guard let apk = Bundle.module.url(forResource: "appliance", withExtension: "apk") else {
            throw AndroidEmulatorError.nativeDisplayUnavailable
        }
        let digest = SHA256.hash(data: try Data(contentsOf: apk)).map { String(format: "%02x", $0) }.joined()
        let receipt = dataDirectory.appending(path: "appliance-version.txt")
        let installed = (try? await command(paths, serial, ["shell", "pm", "path", "dev.mbjfw.appliance"])) ?? ""
        if (try? String(contentsOf: receipt, encoding: .utf8)) != digest || !installed.contains("package:") {
            _ = try await command(paths, serial, ["install", "-r", "-t", apk.path])
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

    private static func command(_ paths: AndroidSDKPaths, _ serial: String, _ arguments: [String]) async throws -> String {
        try await AndroidProcessRunner.run(paths.adb, arguments: ["-s", serial] + arguments, environment: paths.environment(javaHome: paths.javaHome), logURL: paths.launchLog)
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
