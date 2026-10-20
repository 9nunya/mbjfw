import XCTest
@testable import MBJFW
import MBJFWFrameBridge

final class RuntimeRegressionTests: XCTestCase {
    func testReleaseVersionComparisonIsNumericAndToleratesTagPrefix() {
        XCTAssertTrue(ReleaseVersion.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("nightly", than: "1.0.0"))
    }

    func testRuntimeArchitectureSelectsMatchingMacAndAndroidArtifacts() throws {
        let appleSilicon = RuntimeArchitecture.arm64
        XCTAssertEqual(appleSilicon.androidABI, "arm64-v8a")
        XCTAssertEqual(appleSilicon.systemImage, "system-images;android-35;google_apis;arm64-v8a")
        XCTAssertEqual(appleSilicon.qemuHostDirectory, "darwin-aarch64")
        XCTAssertEqual(appleSilicon.qemuGuestExecutable, "qemu-system-aarch64")
        XCTAssertEqual(appleSilicon.hidResourceName, "mbjfw-hid-arm64")
        XCTAssertEqual(appleSilicon.emulatorArchiveURL, "https://dl.google.com/android/repository/emulator-darwin_aarch64-16428233.zip")
        XCTAssertEqual(appleSilicon.runtimeRootDirectoryName, "android-runtime")

        let intel = RuntimeArchitecture.x86_64
        XCTAssertEqual(intel.androidABI, "x86_64")
        XCTAssertEqual(intel.systemImage, "system-images;android-35;google_apis;x86_64")
        XCTAssertEqual(intel.systemImageArchiveURL, "https://dl.google.com/android/repository/sys-img/google_apis/x86_64-35_r09.zip")
        XCTAssertEqual(intel.qemuHostDirectory, "darwin-x86_64")
        XCTAssertEqual(intel.qemuGuestExecutable, "qemu-system-x86_64")
        XCTAssertEqual(intel.hidResourceName, "mbjfw-hid-x86_64")
        XCTAssertEqual(intel.emulatorArchiveURL, "https://dl.google.com/android/repository/emulator-darwin_x64-16428233.zip")
        XCTAssertEqual(intel.runtimeRootDirectoryName, "android-runtime-x86_64")
        XCTAssertTrue(intel.javaRuntimeURL.contains("/mac/x64/"))
        XCTAssertTrue(intel.commandToolsURL.contains("mac_x86_64"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flatBundle = root.appending(path: PackagedResourceLocator.resourceBundleName)
        try FileManager.default.createDirectory(at: flatBundle, withIntermediateDirectories: true)
        let flatFile = flatBundle.appending(path: "mbjfw-hid-x86_64")
        try Data("helper".utf8).write(to: flatFile)
        XCTAssertEqual(PackagedResourceLocator.url(named: "mbjfw-hid-x86_64", inResourceDirectory: root), flatFile)

        let nested = root.appending(path: PackagedResourceLocator.resourceBundleName).appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appending(path: "appliance.apk")
        try Data("apk".utf8).write(to: nestedFile)
        XCTAssertEqual(PackagedResourceLocator.url(named: "appliance.apk", inResourceDirectory: root), nestedFile)

        let paths = AndroidSDKPaths(root: URL(fileURLWithPath: "/tmp/mbjfw-intel"), architecture: .x86_64)
        XCTAssertTrue(paths.systemImageDirectory.path.hasSuffix("system-images/android-35/google_apis/x86_64"))
        XCTAssertEqual(paths.systemImageArchive.lastPathComponent, "android-35-google-apis-x86_64.zip")
    }

    func testDownloadProgressExplainsBytesRateAndRemainingTime() throws {
        let value = try XCTUnwrap(DownloadProgress.curl("34 1695M 34 578M 0 0 12.4M 0 0:02:16 0:00:46 0:01:30 12.4M"))
        XCTAssertEqual(value.fraction, 0.34, accuracy: 0.001)
        XCTAssertTrue(value.detail.contains("of"))
        XCTAssertTrue(value.detail.contains("/s"))
        XCTAssertTrue(value.detail.contains("0:01:30 remaining"))
        XCTAssertNil(DownloadProgress.curl("curl: connection reset"))
    }

    func testInterruptedRestoreFinishesWithoutLosingPreviousData() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let target = root.appending(path: "android-avd")
        let staging = root.appending(path: ".restore/validated")
        let recovery = root.appending(path: "recovery/old")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        try files.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data("restored".utf8).write(to: staging.appending(path: "disk"))
        try Data("previous".utf8).write(to: recovery.appending(path: "disk"))
        let journal: [String: String] = ["staging": staging.absoluteString, "destination": target.absoluteString, "recovery": recovery.absoluteString]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appending(path: "profile-restore-journal.json"))
        try ProfileReplacement.recover(destination: target)
        XCTAssertEqual(try String(contentsOf: target.appending(path: "disk"), encoding: .utf8), "restored")
        XCTAssertEqual(try String(contentsOf: recovery.appending(path: "disk"), encoding: .utf8), "previous")
        XCTAssertFalse(files.fileExists(atPath: root.appending(path: "profile-restore-journal.json").path))
    }
    func testActualMinecraftBinaryManifestMatchesAndroidTools() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "AndroidManifest", withExtension: "xml", subdirectory: "Fixtures"))
        let manifest = try BinaryManifest(data: Data(contentsOf: file))
        XCTAssertEqual(manifest.package, "com.mojang.minecraftpe")
        XCTAssertEqual(manifest.version, "1.26.52.3")
        XCTAssertEqual(manifest.versionCode, 972_605_203)
        XCTAssertEqual(manifest.minimumSDK, 32)
        XCTAssertFalse(manifest.split)
    }

    func testTruncatedManifestIsRejected() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "AndroidManifest", withExtension: "xml", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: file)
        for count in [0, 7, 28, 128, data.count - 1] {
            XCTAssertThrowsError(try BinaryManifest(data: Data(data.prefix(count))))
        }
    }

    func testProfileAPKAndSettingsPersistIndependentlyThroughCodable() throws {
        let first = PlayerAccount(
            id: UUID(), name: "Survival", selectedBuildID: "build-a",
            settings: ProfileSettings(graphicsMode: "host", guestResolution: "1920x1080", guestDensity: "200", guestMemory: 6144, guestCores: 6, disableGameAudio: true, displayFollowsWindow: false)
        )
        let second = PlayerAccount(id: UUID(), name: "Creative", selectedBuildID: "build-b")
        let decoded = try JSONDecoder().decode([PlayerAccount].self, from: JSONEncoder().encode([first, second]))
        XCTAssertEqual(decoded, [first, second])
        XCTAssertNotEqual(decoded[0].selectedBuildID, decoded[1].selectedBuildID)
        XCTAssertNotEqual(decoded[0].settings, decoded[1].settings)
    }

    func testNativeNoticeSharedMemoryRoundTrip() throws {
        let name = "mbjfw-t-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let session = try XCTUnwrap(name.withCString { mbjfw_native_session_create($0, 1280, 720) })
        defer { name.withCString { mbjfw_native_session_destroy(session, $0) } }
        "Minecraft returned to the foreground.".withCString {
            mbjfw_native_session_notice(session, $0, UInt32(MBJFWNativeNoticeInformation.rawValue), 4500)
        }
        var generation: UInt64 = 0
        var kind: UInt32 = 0
        var duration: UInt32 = 0
        var buffer = [CChar](repeating: 0, count: 512)
        let received = buffer.withUnsafeMutableBufferPointer { pointer in
            mbjfw_native_session_read_notice(session, &generation, &kind, &duration, pointer.baseAddress, UInt32(pointer.count))
        }
        XCTAssertEqual(received, 1)
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Minecraft returned to the foreground.")
        XCTAssertEqual(kind, UInt32(MBJFWNativeNoticeInformation.rawValue))
        XCTAssertEqual(duration, 4500)
        XCTAssertEqual(buffer.withUnsafeMutableBufferPointer { pointer in
            mbjfw_native_session_read_notice(session, &generation, &kind, &duration, pointer.baseAddress, UInt32(pointer.count))
        }, 0)
    }

    @MainActor
    func testConcurrentCommandsDoNotReadEachOthersSharedLog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "shared.log")
        async let first = AndroidProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'FIRST'; sleep 0.2; printf 'DONE'"], environment: [:], logURL: log)
        async let second = AndroidProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'SECOND'"], environment: [:], logURL: log)
        let outputs = try await (first, second)
        XCTAssertEqual(outputs.0, "FIRSTDONE")
        XCTAssertEqual(outputs.1, "SECOND")
    }

    @MainActor
    func testBackupRestoreKeepsPreviousDiskAndRejectsTampering() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "android-avd")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appending(path: "userdata-qemu.img")
        try Data("saved world fixture".utf8).write(to: disk)
        let account = PlayerAccount(id: UUID(), name: "Backup test")
        let archive = try await ProfileBackupStore.create(account: account, source: directory)
        try Data("new world fixture".utf8).write(to: disk)
        let restored = try await ProfileBackupStore.restore(archive: archive, account: account, destination: directory)
        let recovery = try XCTUnwrap(restored)
        XCTAssertEqual(try String(contentsOf: disk, encoding: .utf8), "saved world fixture")
        XCTAssertEqual(try String(contentsOf: recovery.appending(path: "userdata-qemu.img"), encoding: .utf8), "new world fixture")
        try Data("tampered".utf8).write(to: archive)
        do {
            _ = try await ProfileBackupStore.restore(archive: archive, account: account, destination: directory)
            XCTFail("A corrupt archive must not replace a profile")
        } catch { XCTAssertTrue(error is ProfileBackupError) }
        XCTAssertEqual(try String(contentsOf: disk, encoding: .utf8), "saved world fixture")
    }
}
