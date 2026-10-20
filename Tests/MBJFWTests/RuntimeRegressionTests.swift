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
            settings: ProfileSettings(graphicsMode: "host", guestResolution: "1920x1080", guestDensity: "200", guestMemory: 6144, guestCores: 6, disableGameAudio: true, hostMicrophoneEnabled: true, displayFollowsWindow: false)
        )
        let second = PlayerAccount(id: UUID(), name: "Creative", selectedBuildID: "build-b")
        let decoded = try JSONDecoder().decode([PlayerAccount].self, from: JSONEncoder().encode([first, second]))
        XCTAssertEqual(decoded, [first, second])
        XCTAssertNotEqual(decoded[0].selectedBuildID, decoded[1].selectedBuildID)
        XCTAssertNotEqual(decoded[0].settings, decoded[1].settings)
    }

    func testOlderProfileSettingsDecodeWithMicrophoneDisabled() throws {
        let encoded = #"{"id":"AB25EC78-B362-4107-BF28-60EEAACAC652","name":"Survival","settings":{"graphicsMode":"host","guestResolution":"1920x1080","guestDensity":"160","guestMemory":4096,"guestCores":4,"disableGameAudio":false,"displayFollowsWindow":true}}"#.data(using: .utf8)!
        let account = try JSONDecoder().decode(PlayerAccount.self, from: encoded)
        XCTAssertFalse(account.settings.hostMicrophoneEnabled)
        XCTAssertEqual(account.settings.guestResolution, "1920x1080")
    }

    func testEmulatorFlagsKeepHWCResizeWithoutPixelFoldOverlay() {
        let features = Set(AndroidEmulatorLaunchOptions.features.split(separator: ",").map(String.init))
        XCTAssertTrue(features.contains("HWCMultiConfigs"))
        XCTAssertTrue(features.contains("-SupportPixelFold"))
        XCTAssertFalse(features.contains("SupportPixelFold"))
        XCTAssertTrue(features.contains("-DeviceSkinOverlay"))
        XCTAssertEqual(AndroidEmulatorLaunchOptions.displayArguments, ["-qt-hide-window"])
    }

    func testAndroidBootWaitsForActivityAndPackageServicesAfterBootProperty() {
        XCTAssertFalse(AndroidBootReadiness.isReady(
            bootCompleted: "1",
            activityService: "Service activity: not found",
            packageService: "Service package: found"
        ))
        XCTAssertFalse(AndroidBootReadiness.isReady(
            bootCompleted: "1",
            activityService: "Service activity: found",
            packageService: nil
        ))
        XCTAssertTrue(AndroidBootReadiness.isReady(
            bootCompleted: "1\n",
            activityService: "Service activity: found",
            packageService: "Service package: found"
        ))
    }

    @MainActor
    func testOptionalPackageManagerDisconnectDoesNotBecomeFatalProvisioningError() {
        let brokenPipe = AndroidCommandError(
            command: "adb -s emulator-5580 shell pm disable-user --user 0 com.android.camera2",
            status: 224,
            output: "Failure calling service package: Broken pipe (32)"
        )
        let unrelatedFailure = AndroidCommandError(
            command: "adb -s emulator-5580 shell pm disable-user --user 0 com.android.camera2",
            status: 1,
            output: "Unknown package: com.android.camera2"
        )

        XCTAssertTrue(AndroidAppliancePolicy.isTransientPackageServiceFailure(brokenPipe))
        XCTAssertFalse(AndroidAppliancePolicy.isTransientPackageServiceFailure(unrelatedFailure))

        let result = AndroidApplianceResult(disabledPackages: 12, skippedPackages: ["com.android.camera2"])
        XCTAssertTrue(result.progressDetail.contains("12 optional apps disabled"))
        XCTAssertTrue(result.progressDetail.contains("com.android.camera2"))
    }

    @MainActor
    func testLegacyDisabledPackageVerifierCanBeDetectedForInstallRecovery() {
        let disabled = AndroidAppliancePolicy.disabledPackageNames(in: """
            package:com.android.vending
            package:com.google.android.apps.photos
            """)
        XCTAssertTrue(disabled.contains("com.android.vending"))
        XCTAssertFalse(AndroidAppliancePolicy.disabledPackageNames(in: "package:com.google.android.apps.photos\n").contains("com.android.vending"))
    }

    @MainActor
    func testAPKInstallRetryUsesPushModeAndKeepsProfileData() {
        let firstAttempt = AndroidAppliancePolicy.installArguments(
            apkPath: "/tmp/minecraft.apk",
            attempt: 0,
            testOnly: false
        )
        let retry = AndroidAppliancePolicy.installArguments(
            apkPath: "/tmp/minecraft.apk",
            attempt: 1,
            testOnly: false
        )
        let appliance = AndroidAppliancePolicy.installArguments(
            apkPath: "/tmp/appliance.apk",
            attempt: 1,
            testOnly: true
        )

        XCTAssertEqual(firstAttempt, ["install", "-r", "/tmp/minecraft.apk"])
        XCTAssertEqual(retry, ["install", "-r", "--no-streaming", "/tmp/minecraft.apk"])
        XCTAssertTrue(retry.contains("-r"), "Retries must update in place and preserve Minecraft profile data.")
        XCTAssertTrue(appliance.contains("-t"), "The appliance APK is a test package.")
    }

    func testAudioRoutesThroughCoreAudioAndEnablesMicOnlyByProfileOptIn() {
        let outputOnly = EmulatorAudioConfiguration(settings: .default)
        XCTAssertEqual(outputOnly.arguments, [])
        XCTAssertEqual(outputOnly.environment["QEMU_AUDIO_OUT_DRV"], "coreaudio")
        XCTAssertEqual(outputOnly.environment["QEMU_AUDIO_IN_DRV"], "none")

        var microphoneProfile = ProfileSettings.default
        microphoneProfile.hostMicrophoneEnabled = true
        let microphone = EmulatorAudioConfiguration(settings: microphoneProfile)
        XCTAssertEqual(microphone.arguments, ["-allow-host-audio"])
        XCTAssertEqual(microphone.environment["QEMU_AUDIO_IN_DRV"], "coreaudio")

        microphoneProfile.disableGameAudio = true
        let microphoneOnly = EmulatorAudioConfiguration(settings: microphoneProfile)
        XCTAssertEqual(microphoneOnly.environment["QEMU_AUDIO_OUT_DRV"], "none")
        XCTAssertEqual(microphoneOnly.environment["QEMU_AUDIO_IN_DRV"], "coreaudio")
        XCTAssertFalse(microphoneOnly.arguments.contains("-no-audio"))
    }

    @MainActor
    func testProfileAVDsUseSeparateRegistriesAndKeepAudioHardwareEnabled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AndroidSDKPaths(root: root.appending(path: "runtime"))
        let template = paths.avdHome.appending(path: "MBJFW.avd/config.ini")
        try FileManager.default.createDirectory(at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "hw.audioInput=no\nhw.audioOutput=no\nhw.device.name=resizable\nhw.ramSize=4096\n".write(to: template, atomically: true, encoding: .utf8)

        let first = PlayerAccount(id: UUID(), name: "First")
        let second = PlayerAccount(id: UUID(), name: "Second")
        let firstDirectory = root.appending(path: "accounts/\(first.id.uuidString)/android-avd")
        let secondDirectory = root.appending(path: "accounts/\(second.id.uuidString)/android-avd")
        let firstRegistry = try await ProfileDevice.prepare(account: first, directory: firstDirectory, settings: .default, paths: paths)
        let secondRegistry = try await ProfileDevice.prepare(account: second, directory: secondDirectory, settings: .default, paths: paths)

        XCTAssertNotEqual(firstRegistry, secondRegistry)
        let firstConfig = try String(contentsOf: firstDirectory.appending(path: "config.ini"), encoding: .utf8)
        let secondConfig = try String(contentsOf: secondDirectory.appending(path: "config.ini"), encoding: .utf8)
        XCTAssertTrue(firstConfig.contains("hw.audioInput=yes"))
        XCTAssertTrue(firstConfig.contains("hw.audioOutput=yes"))
        XCTAssertTrue(firstConfig.contains("hw.device.name=resizable"))
        XCTAssertTrue(secondConfig.contains("disk.dataPartition.path=\(secondDirectory.appending(path: "userdata-qemu.img").path)"))
        XCTAssertFalse(firstConfig.contains("disk.dataPartition.path=\(secondDirectory.path)"))
    }

    @MainActor
    func testEmulatorBootGateSerializesColdBoots() async throws {
        let gate = EmulatorBootGate()
        var events: [String] = []
        let first = Task { @MainActor in
            let waited = try await gate.acquire()
            XCTAssertFalse(waited)
            events.append("first-start")
            try await Task.sleep(for: .milliseconds(40))
            events.append("first-end")
            gate.release()
        }
        let second = Task { @MainActor in
            let waited = try await gate.acquire()
            XCTAssertTrue(waited)
            events.append("second-start")
            gate.release()
        }
        try await first.value
        try await second.value
        XCTAssertEqual(events, ["first-start", "first-end", "second-start"])
    }

    @MainActor
    func testEmulatorPortLeasesAreDistinctAndReleasedAfterStop() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try EmulatorPortLease.reserve(in: root, adbDevices: "List of devices attached\n")
        let second = try EmulatorPortLease.reserve(in: root, adbDevices: "List of devices attached\n")
        XCTAssertEqual(first.port, 5580)
        XCTAssertEqual(second.port, 5582)

        first.release()
        let replacement = try EmulatorPortLease.reserve(
            in: root,
            adbDevices: "List of devices attached\nemulator-5582\toffline\n"
        )
        XCTAssertEqual(replacement.port, 5580)
        second.release()
        replacement.release()
    }

    @MainActor
    func testAndroidCommandTimeoutTerminatesWaitingSubprocess() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "mbjfw-timeout-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: log) }

        do {
            _ = try await AndroidProcessRunner.run(
                URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: [:],
                logURL: log,
                timeout: .milliseconds(50)
            )
            XCTFail("Expected the sleeping command to time out")
        } catch is AndroidCommandTimedOut {
        }
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
