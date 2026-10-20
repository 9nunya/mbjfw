import Foundation

enum RuntimeArchitecture: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    static var current: RuntimeArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        preconditionFailure("MBJFW supports Apple Silicon and Intel 64-bit Macs.")
        #endif
    }

    var displayName: String {
        switch self {
        case .arm64: "Apple Silicon"
        case .x86_64: "Intel"
        }
    }

    var androidABI: String { rawValue == "arm64" ? "arm64-v8a" : "x86_64" }
    var systemImage: String { "system-images;android-35;google_apis;\(androidABI)" }
    var systemImageDirectory: String { "system-images/android-35/google_apis/\(androidABI)" }
    var systemImageArchiveName: String { "android-35-google-apis-\(androidABI).zip" }
    var systemImageArchiveURL: String {
        "https://dl.google.com/android/repository/sys-img/google_apis/\(androidABI)-35_r09.zip"
    }
    var javaRuntimeURL: String {
        let javaArchitecture = self == .arm64 ? "aarch64" : "x64"
        return "https://api.adoptium.net/v3/binary/latest/21/ga/mac/\(javaArchitecture)/jre/hotspot/normal/eclipse"
    }
    var commandToolsURL: String {
        let archiveArchitecture = self == .arm64 ? "arm64" : "x86_64"
        return "https://dl.google.com/android/repository/commandlinetools-mac_\(archiveArchitecture)-15859902_latest.zip"
    }
    var commandToolsSHA256: String {
        switch self {
        case .arm64: "835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e"
        case .x86_64: "c5a6378ab5cf7e0d5701921405115befff13e9ff7417fb588389338f8bd050f3"
        }
    }
    var emulatorRevision: String { "37.2.12" }
    var emulatorBuildID: String { "16428233" }
    var emulatorArchiveName: String { "emulator-\(rawValue)-\(emulatorBuildID).zip" }
    var emulatorArchiveURL: String {
        let archiveArchitecture = self == .arm64 ? "aarch64" : "x64"
        return "https://dl.google.com/android/repository/emulator-darwin_\(archiveArchitecture)-\(emulatorBuildID).zip"
    }
    var qemuHostDirectory: String { self == .arm64 ? "darwin-aarch64" : "darwin-x86_64" }
    var qemuGuestExecutable: String { self == .arm64 ? "qemu-system-aarch64" : "qemu-system-x86_64" }
    var hidResourceName: String { "mbjfw-hid-\(rawValue)" }
    var runtimeDescription: String {
        self == .arm64 ? "Android 15 · ARM64" : "Android 15 · Intel x86_64 with ARM64 app support"
    }
    var runtimeRootDirectoryName: String { self == .arm64 ? "android-runtime" : "android-runtime-x86_64" }
}
