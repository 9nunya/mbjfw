import Foundation

@MainActor
enum ProfileDevice {
    /// AVD registration owns every writable disk, not merely a -datadir hint.
    static func prepare(account: PlayerAccount, directory: URL, settings: ProfileSettings, paths: AndroidSDKPaths) async throws -> URL {
        let files = FileManager.default
        try ProfileReplacement.recover(destination: directory)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appending(path: "config.ini")
        let migration = directory.appending(path: "legacy-migration.txt")
        if let record = try? String(contentsOf: migration, encoding: .utf8), !record.hasPrefix("format=2\n") {
            let recovery = directory.deletingLastPathComponent().appending(path: "recovery/migration-\(UUID())")
            try files.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: directory, to: recovery)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["installed-minecraft.json", "appliance-version.txt"] {
                let source = recovery.appending(path: name)
                if files.fileExists(atPath: source.path) { try files.copyItem(at: source, to: directory.appending(path: name)) }
            }
        }
        if !files.fileExists(atPath: config.path) {
            try await migrateSharedDevice(account: account, directory: directory, paths: paths)
        }
        let template = try String(contentsOf: paths.avdHome.appending(path: "MBJFW.avd/config.ini"), encoding: .utf8)
        // Never carry absolute writable image paths or phone hardware emulation
        // from the shared device into a profile's independently registered AVD.
        let excluded = ["disk.dataPartition.path", "disk.cachePartition.path", "disk.encryptionKeyPartition.path", "hw.sdCard", "hw.sdCard.path", "skin.path", "skin.name"]
        var values: [String: String] = [:]
        for line in template.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0]] = pair[1]
        }
        for key in excluded { values.removeValue(forKey: key) }
        let dimensions = settings.guestResolution.split(separator: "x").compactMap { Int($0) }
        let width = dimensions.first ?? 1280
        let height = dimensions.dropFirst().first ?? 720
        values["hw.keyboard"] = "yes"
        values["hw.audioInput"] = "yes"
        values["hw.audioOutput"] = "yes"
        values["hw.device.name"] = "resizable"
        values["hw.device.manufacturer"] = "Android"
        values.removeValue(forKey: "hw.device.hash2")
        values["hw.initialOrientation"] = "landscape"
        values["hw.lcd.width"] = String(width)
        values["hw.lcd.height"] = String(height)
        values["hw.lcd.density"] = settings.guestDensity
        values["hw.resizable.configs"] = [
            "phone-0-1280-720-\(settings.guestDensity)",
            "foldable-1-1600-900-\(settings.guestDensity)",
            "tablet-2-1920-1080-\(settings.guestDensity)"
        ].joined(separator: ",")
        values["hw.gpu.enabled"] = "yes"
        values["hw.gpu.mode"] = "host"
        values["hw.cpu.ncore"] = String(settings.guestCores)
        values["hw.ramSize"] = String(settings.guestMemory)
        values["showDeviceFrame"] = "no"
        values["fastboot.forceColdBoot"] = "no"
        values["fastboot.forceFastBoot"] = "yes"
        values["hw.sdCard"] = "no"
        values["skin.name"] = settings.guestResolution
        values["disk.dataPartition.path"] = directory.appending(path: "userdata-qemu.img").path
        values["disk.cachePartition.path"] = directory.appending(path: "cache.img").path
        values["disk.encryptionKeyPartition.path"] = directory.appending(path: "encryptionkey.img").path
        let lines = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try lines.joined(separator: "\n").appending("\n").write(to: config, atomically: true, encoding: .utf8)
        let registry = directory.deletingLastPathComponent().appending(path: "device-registry")
        try files.createDirectory(at: registry, withIntermediateDirectories: true)
        try "avd.ini.encoding=UTF-8\npath=\(directory.path)\ntarget=android-35\n".write(to: registry.appending(path: "MBJFW.ini"), atomically: true, encoding: .utf8)
        return registry
    }

    private static func migrateSharedDevice(account: PlayerAccount, directory: URL, paths: AndroidSDKPaths) async throws {
        let files = FileManager.default
        let shared = paths.avdHome.appending(path: "MBJFW.avd")
        let claim = paths.root.appending(path: "legacy-device-owner.txt")
        if let owner = try? String(contentsOf: claim, encoding: .utf8), owner != account.id.uuidString { return }
        // A new profile must never inherit another player's legacy shared device.
        guard files.fileExists(atPath: directory.appending(path: "installed-minecraft.json").path),
              files.fileExists(atPath: shared.appending(path: "userdata-qemu.img").path) else { return }
        try account.id.uuidString.write(to: claim, atomically: true, encoding: .utf8)
        // Quick Boot overlays carry disk state independently of the base image.
        // Flatten them into standalone profile bases before starting a cold VM.
        let imageTool = paths.emulator.deletingLastPathComponent().appending(path: "qemu-img")
        for name in ["userdata-qemu.img", "encryptionkey.img"] {
            let overlay = shared.appending(path: name + ".qcow2")
            let destination = directory.appending(path: name)
            if files.fileExists(atPath: overlay.path), !files.fileExists(atPath: destination.path) {
                let staging = directory.appending(path: ".migrating-\(name)")
                if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
                try await AndroidProcessRunner.run(imageTool, arguments: ["convert", "-O", "qcow2", overlay.path, staging.path], environment: [:], logURL: paths.launchLog)
                try files.moveItem(at: staging, to: destination)
            }
        }
        let names = ["userdata-qemu.img", "encryptionkey.img", "modem_simulator", "data"]
        for name in names {
            let source = shared.appending(path: name), destination = directory.appending(path: name)
            guard files.fileExists(atPath: source.path), !files.fileExists(atPath: destination.path) else { continue }
            let staging = directory.appending(path: ".migrating-\(name)")
            if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            // APFS clones retain an independent recovery copy without duplicating
            // several GB of blocks. ditto is the fallback on other filesystems.
            do {
                try await AndroidProcessRunner.run(URL(fileURLWithPath: "/bin/cp"), arguments: ["-cR", source.path, staging.path], environment: [:], logURL: paths.launchLog)
            } catch {
                if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
                try await AndroidProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [source.path, staging.path], environment: [:], logURL: paths.launchLog)
            }
            try files.moveItem(at: staging, to: destination)
        }
        try "format=2\nThe original shared AVD is retained at \(shared.path).\n".write(to: directory.appending(path: "legacy-migration.txt"), atomically: true, encoding: .utf8)
    }
}
