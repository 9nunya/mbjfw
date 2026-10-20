import Foundation

/// Gives the renderer helper a macOS application identity while retaining the
/// installed emulator's binary and libraries. The Android image is unchanged.
enum NativeRuntimeBundle {
    static func prepare(paths: AndroidSDKPaths) throws -> URL {
        let emulatorRoot = paths.emulator.deletingLastPathComponent()
        let source = emulatorRoot.appending(path: "qemu/darwin-aarch64/qemu-system-aarch64")
        let bundle = paths.root.appending(path: "native-host/Minecraft.app")
        let contents = bundle.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let executable = macOS.appending(path: "NativeGameHost")
        let receipt = contents.appending(path: "runtime-source.json")
        let revision = try String(contentsOf: emulatorRoot.appending(path: "source.properties"), encoding: .utf8)
        guard revision.contains("Pkg.Revision=37.2.12"), revision.contains("Pkg.BuildId=16428233"),
              try FileDigest.sha256(source) == "8dcdec74dc2d2cf4d9cfbf8146506b48e13d389ae59ef5be1966ff72d44af033" else {
            throw NativeRuntimeError.unsupportedVersion
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceRecord = RuntimeSource(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            revision: revision
        )
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let oldRecord = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode(RuntimeSource.self, from: $0) }
        if oldRecord != sourceRecord || !FileManager.default.isExecutableFile(atPath: executable.path) {
            let staging = executable.appendingPathExtension("staging")
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            if FileManager.default.fileExists(atPath: executable.path) {
                _ = try FileManager.default.replaceItemAt(executable, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: executable)
            }
            try JSONEncoder().encode(sourceRecord).write(to: receipt, options: .atomic)
        }
        let info: [String: Any] = [
            "CFBundleExecutable": "NativeGameHost", "CFBundleIdentifier": "dev.mbjfw.gamehost",
            "CFBundleName": "Minecraft", "CFBundleDisplayName": "Minecraft",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "15.0", "LSUIElement": true, "NSHighResolutionCapable": true
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"), options: .atomic)
        let libraries = macOS.appending(path: "lib64")
        if !FileManager.default.fileExists(atPath: libraries.path) {
            try FileManager.default.createSymbolicLink(at: libraries, withDestinationURL: emulatorRoot.appending(path: "lib64"))
        }
        return executable
    }

    static func environment(paths: AndroidSDKPaths) -> [String: String] {
        let root = paths.emulator.deletingLastPathComponent()
        let libraries = root.appending(path: "lib64")
        return [
            "ANDROID_EMULATOR_LAUNCHER_DIR": root.path,
            "DYLD_LIBRARY_PATH": [libraries.path, libraries.appending(path: "qt/lib").path,
                                  libraries.appending(path: "gles_angle").path, libraries.appending(path: "vulkan").path].joined(separator: ":"),
            "QT_PLUGIN_PATH": libraries.appending(path: "qt/plugins").path,
            "QT_QPA_PLATFORM_PLUGIN_PATH": libraries.appending(path: "qt/plugins").path,
            "QTWEBENGINE_RESOURCES_PATH": libraries.appending(path: "qt/resources").path,
            "QTWEBENGINE_LOCALES_PATH": libraries.appending(path: "qt/translations/qtwebengine_locales").path,
            // A hidden Qt window cannot answer the emulator's crash-consent
            // dialog. Keep old crash reports local and let headless startup proceed.
            "ANDROID_EMU_ENABLE_CRASH_REPORTING": "disabled"
        ]
    }

    private struct RuntimeSource: Codable, Equatable {
        let size: UInt64
        let modified: TimeInterval
        let revision: String
    }
}

private enum NativeRuntimeError: LocalizedError {
    case unsupportedVersion
    var errorDescription: String? { "This native host requires Android Emulator 37.2.12 (16428233). The installed runtime differs from the verified artifact; your profile has been preserved." }
}
