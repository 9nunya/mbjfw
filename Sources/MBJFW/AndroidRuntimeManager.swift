import Foundation
import SwiftUI
import AppKit
import MBJFWFrameBridge

@MainActor
@Observable
final class AndroidRuntimeManager {
    var profileSettings: ProfileSettings
    private(set) var isInstalling = false
    private(set) var isLaunching = false
    private(set) var isStopping = false
    private(set) var steps: [GameLaunchStep] = []
    private(set) var pipelineError: String?
    private(set) var isGameRunning = false
    private(set) var activeBuildID: String?
    private(set) var guestRequestsPointerCapture = false
    var gameWindowToken = 0
    var needsLicenseConsent = false
    var statusMessage = "Android runtime installs the first time you play."

    private let runtimeRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/MBJFW/\(RuntimeArchitecture.current.runtimeRootDirectoryName)")
    private(set) var paths: AndroidSDKPaths
    private let session = AndroidEmulatorSession()
    private var pendingLaunch: PendingAndroidLaunch?
    private var lastLaunch: PendingAndroidLaunch?
    private var launchTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var nativeWindowTask: Task<Void, Never>?
    private var nativeResizeTask: Task<Void, Never>?
    private var requestedLauncherActivation = false
    private var lastNotice: String?

    init(settings: ProfileSettings = .default) {
        profileSettings = settings
        paths = AndroidSDKPaths(root: runtimeRoot)
        session.onProcessExit = { [weak self] in
            self?.isGameRunning = false
            self?.activeBuildID = nil
            self?.isLaunching = false
            self?.foregroundTask?.cancel()
            self?.foregroundTask = nil
            self?.nativeWindowTask?.cancel()
            self?.nativeWindowTask = nil
            self?.nativeResizeTask?.cancel()
            self?.nativeResizeTask = nil
            self?.statusMessage = "Android stopped. Your profile data is preserved."
        }
    }

    var isReady: Bool { paths.isReady }
    var activeSerial: String? { session.serial }

    func updateSettings(_ settings: ProfileSettings) {
        profileSettings = settings
        session.setNativeDisplayFollowsWindow(settings.displayFollowsWindow)
    }

    func showInGameNotice(_ message: String, kind: UInt32 = 0) {
        guard isGameRunning, !message.isEmpty, message != lastNotice else { return }
        lastNotice = message
        session.showNativeNotice(message, kind: kind)
    }

    func focusGameWindow() { session.focusGameWindow() }

    func setDisplayFollowsWindow(_ enabled: Bool) {
        session.setNativeDisplayFollowsWindow(enabled)
    }

    func showLauncherWindow() {
        requestedLauncherActivation = !NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.identifier?.rawValue != "game" }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationBecameActive() {
        if requestedLauncherActivation { requestedLauncherActivation = false; return }
        // Clicking the launcher should still let the user configure it. Dock
        // and Command-Tab activation bring the running native game forward.
        if isGameRunning && NSEvent.pressedMouseButtons == 0 { focusGameWindow() }
    }

    func cancelPreparation() {
        if isInstalling {
            pendingLaunch = nil
            installTask?.cancel()
        }
        if isLaunching { stopGame() }
    }

    func stopGame() {
        guard !isStopping, isGameRunning || isLaunching else { return }
        isStopping = true
        statusMessage = "Stopping Android…"
        let task = Task { await performStop() }
        stopTask = task
    }

    func stopGameAndWait() async {
        if let stopTask { await stopTask.value; return }
        isStopping = true
        let task = Task { await performStop() }
        stopTask = task
        await task.value
    }

    private func performStop() async {
        statusMessage = "Stopping Android and closing the game…"
        foregroundTask?.cancel()
        foregroundTask = nil
        nativeWindowTask?.cancel()
        nativeWindowTask = nil
        nativeResizeTask?.cancel()
        nativeResizeTask = nil
        launchTask?.cancel()
        await session.stop(paths: paths)
        await launchTask?.value
        launchTask = nil
        isStopping = false
        isLaunching = false
        isGameRunning = false
        activeBuildID = nil
        statusMessage = "Game stopped. Your profile data is preserved."
        stopTask = nil
    }

    func applyDisplay(width: Int, height: Int, density: Int? = nil) async throws {
        guard let serial = session.serial else { throw AndroidEmulatorError.deviceNotReady }
        let requestedDensity = density ?? Int(profileSettings.guestDensity) ?? 160
        guard width >= 640, height >= 360, width <= 4096, height <= 4096, (100...320).contains(requestedDensity) else { throw DisplayConfigurationError.invalid }
        let modes = [(1280,720),(1600,900),(1920,1080)]
        let selected = modes.min { lhs, rhs in
            let left = abs(log(Double(lhs.0) / Double(width))) + abs(log(Double(lhs.1) / Double(height)))
            let right = abs(log(Double(rhs.0) / Double(width))) + abs(log(Double(rhs.1) / Double(height)))
            return left < right
        } ?? modes[0]
        let environment = paths.environment(javaHome: paths.javaHome)
        let expected = "\(selected.0)x\(selected.1)"
        let currentDensity = try await AndroidProcessRunner.run(paths.adb, arguments: ["-s", serial, "shell", "wm", "density"], environment: environment, logURL: paths.launchLog)
        try Task.checkCancellation()
        session.setNativeGeometry(width: selected.0, height: selected.1)
        _ = try await AndroidProcessRunner.run(
            paths.adb,
            arguments: ["-s", serial, "shell", "wm", "size", expected],
            environment: environment,
            logURL: paths.launchLog
        )
        var displayReady = false
        for _ in 0..<35 {
            try Task.checkCancellation()
            let metrics = try await AndroidProcessRunner.run(paths.adb, arguments: ["-s", serial, "shell", "wm", "size"], environment: environment, logURL: paths.launchLog)
            let effective = metrics.split(whereSeparator: \.isNewline).last
            if effective?.hasSuffix(expected) == true { displayReady = true; break }
            try await Task.sleep(for: .milliseconds(80))
        }
        guard displayReady else { throw DisplayConfigurationError.unacknowledged }
        if currentDensity.split(whereSeparator: \.isNewline).last?.hasSuffix(" \(requestedDensity)") != true {
            try await AndroidProcessRunner.run(paths.adb, arguments: ["-s", serial, "shell", "wm", "density", "\(requestedDensity)"], environment: environment, logURL: paths.launchLog)
        }
        let acknowledged = try await AndroidProcessRunner.run(paths.adb, arguments: ["-s", serial, "shell", "wm", "size"], environment: environment, logURL: paths.launchLog)
        guard acknowledged.split(whereSeparator: \.isNewline).last?.hasSuffix(expected) == true else { throw DisplayConfigurationError.unacknowledged }
        try Task.checkCancellation()
        session.setNativeGeometry(width: selected.0, height: selected.1)
    }

    func refreshPointerCaptureRequest() async {
        guard let serial = session.serial else { guestRequestsPointerCapture = false; return }
        do {
            let state = try await AndroidProcessRunner.run(
                paths.adb,
                arguments: ["-s", serial, "shell", "dumpsys input | grep 'Pointer Capture Requested:'"],
                environment: paths.environment(javaHome: paths.javaHome),
                logURL: paths.launchLog
            )
            guestRequestsPointerCapture = state.contains("Pointer Capture Requested: true")
            session.setNativeCaptureRequest(guestRequestsPointerCapture)
        } catch {
            guestRequestsPointerCapture = false
        }
    }

    func restoreOptionalApps(for account: PlayerAccount, dataDirectory: URL) async throws -> Int {
        guard let serial = session.serial else { throw AndroidEmulatorError.deviceNotReady }
        return try await AndroidAppliancePolicy.restore(serial: serial, dataDirectory: dataDirectory, paths: paths)
    }

    func requestInstall() {
        guard !isReady, !isInstalling else { return }
        if UserDefaults.standard.bool(forKey: "mbjfw.androidSDKConsentAccepted") {
            acceptLicenseAndInstall()
        } else {
            needsLicenseConsent = true
        }
    }

    func launch(apk: URL, account: PlayerAccount, dataDirectory: URL) {
        guard !isStopping else { return }
        if isGameRunning { focusGameWindow(); return }
        paths = AndroidSDKPaths(root: runtimeRoot, sessionLogDirectory: dataDirectory.appending(path: "logs"))
        activeBuildID = account.selectedBuildID
        let request = PendingAndroidLaunch(apk: apk, account: account, dataDirectory: dataDirectory)
        lastLaunch = request
        guard isReady else {
            pendingLaunch = request
            requestInstall()
            return
        }
        run(apk: apk, account: account, dataDirectory: dataDirectory, continuingPipeline: false)
    }

    func acceptLicenseAndInstall() {
        guard !isInstalling else { return }
        UserDefaults.standard.set(true, forKey: "mbjfw.androidSDKConsentAccepted")
        needsLicenseConsent = false
        isInstalling = true
        beginPipeline(stages: GameLaunchStage.allCases)
        gameWindowToken += 1
        installTask = Task { @MainActor in
            defer { isInstalling = false; installTask = nil }
            do {
                _ = try await AndroidSDKInstallCoordinator.install(at: paths.root) { stage, detail, fraction in
                    self.markProgress(stage: stage, detail: detail, progress: fraction)
                }
                try Task.checkCancellation()
                finishActiveStep()
                statusMessage = "Android runtime is ready."
                if let pendingLaunch {
                    self.pendingLaunch = nil
                    run(apk: pendingLaunch.apk, account: pendingLaunch.account, dataDirectory: pendingLaunch.dataDirectory, continuingPipeline: true)
                }
            } catch is CancellationError {
                statusMessage = "Setup paused. Downloaded data will be reused when you retry."
                pipelineError = statusMessage
            } catch {
                failActiveStep(error)
            }
        }
    }

    func declineLicense() {
        needsLicenseConsent = false
        pendingLaunch = nil
        statusMessage = "Android setup is paused until you accept the SDK licenses."
    }

    func retry() {
        pipelineError = nil
        isGameRunning = false
        if let lastLaunch {
            launch(apk: lastLaunch.apk, account: lastLaunch.account, dataDirectory: lastLaunch.dataDirectory)
        } else if steps.contains(where: { $0.stage.isSetupStage }) {
            acceptLicenseAndInstall()
        }
    }

    private func run(apk: URL, account: PlayerAccount, dataDirectory: URL, continuingPipeline: Bool) {
        guard !isLaunching else { return }
        lastLaunch = PendingAndroidLaunch(apk: apk, account: account, dataDirectory: dataDirectory)
        activeBuildID = account.selectedBuildID
        if !continuingPipeline {
            beginPipeline(stages: GameLaunchStage.allCases.filter { !$0.isSetupStage })
            gameWindowToken += 1
        }
        isLaunching = true
        statusMessage = "Starting Bedrock for \(account.name)…"
        launchTask = Task { @MainActor in
            defer { isLaunching = false }
            do {
                try await session.launch(
                    apk: apk,
                    account: account,
                    dataDirectory: dataDirectory,
                    settings: profileSettings,
                    paths: paths
                ) { stage, detail in
                    self.markProgress(stage: stage, detail: detail)
                }
                finishActiveStep()
                isGameRunning = true
                statusMessage = "Bedrock is running."
                startForegroundKeeper()
                superviseNativeWindow()
            } catch {
                if !Task.isCancelled {
                    await session.stop(paths: paths)
                    activeBuildID = nil
                    failActiveStep(error)
                }
            }
        }
    }

    private func superviseNativeWindow() {
        nativeWindowTask?.cancel()
        nativeWindowTask = Task { @MainActor in
            var geometryGeneration: UInt64 = 0
            var launcherRequests: UInt64 = 0
            var ticks = 0
            while !Task.isCancelled && isGameRunning {
                guard let status = session.nativeStatus else { break }
                if status.launcherRequests != launcherRequests {
                    launcherRequests = status.launcherRequests
                    showLauncherWindow()
                }
                if status.stopRequested != 0 { stopGame(); break }
                if status.state == MBJFWNativeFailed.rawValue {
                    pipelineError = "The native game window stopped presenting (code \(status.errorCode))."
                    showInGameNotice(pipelineError ?? "The game display stopped.", kind: 2)
                    stopGame()
                    break
                }
                if status.geometryGeneration != geometryGeneration {
                    geometryGeneration = status.geometryGeneration
                    if profileSettings.displayFollowsWindow {
                        nativeResizeTask?.cancel()
                        let width = Int(status.desiredWidth), height = Int(status.desiredHeight)
                        nativeResizeTask = Task { @MainActor in
                            do {
                                try await Task.sleep(for: .milliseconds(250))
                                try Task.checkCancellation()
                                try await applyDisplay(width: width, height: height)
                            } catch is CancellationError { }
                            catch {
                                statusMessage = "Display resize failed: \(error.localizedDescription)"
                                showInGameNotice(statusMessage, kind: 2)
                            }
                        }
                    }
                }
                if ticks.isMultiple(of: 10) { await refreshPointerCaptureRequest() }
                ticks += 1
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }

    private func startForegroundKeeper() {
        foregroundTask?.cancel()
        foregroundTask = Task { @MainActor in
            while !Task.isCancelled && isGameRunning {
                do {
                    try await Task.sleep(for: .seconds(5))
                    if try await session.restoreGameForeground(paths: paths) {
                        statusMessage = "Minecraft returned to the foreground."
                        showInGameNotice(statusMessage)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if !Task.isCancelled {
                        statusMessage = "Minecraft foreground check: \(error.localizedDescription)"
                        showInGameNotice("Minecraft needs attention: \(error.localizedDescription)", kind: 2)
                    }
                }
            }
        }
    }

    private func beginPipeline(stages: [GameLaunchStage]) {
        steps = stages.map { GameLaunchStep(stage: $0, state: .pending, detail: nil, progress: nil) }
        pipelineError = nil
        isGameRunning = false
    }

    private func markProgress(stage: GameLaunchStage, detail: String, progress: Double? = nil) {
        if let index = steps.firstIndex(where: { $0.stage == stage && $0.state == .active }) {
            steps[index].detail = detail
            steps[index].progress = progress ?? steps[index].progress
            statusMessage = detail
            return
        }
        finishActiveStep()
        guard let index = steps.firstIndex(where: { $0.stage == stage }) else { return }
        steps[index].state = .active
        steps[index].detail = detail
        steps[index].progress = progress
        statusMessage = detail
    }

    private func finishActiveStep() {
        guard let index = steps.firstIndex(where: { $0.state == .active }) else { return }
        steps[index].state = .finished
    }

    private func failActiveStep(_ error: Error) {
        let message = error.localizedDescription
        if let index = steps.firstIndex(where: { $0.state == .active }) {
            steps[index].state = .failed(message)
            steps[index].detail = message
        }
        pipelineError = message
        statusMessage = message
    }
}

private enum DisplayConfigurationError: LocalizedError {
    case invalid, unacknowledged
    var errorDescription: String? {
        switch self {
        case .invalid: "The requested display geometry or density is outside the supported range."
        case .unacknowledged: "Android did not acknowledge the requested display resolution."
        }
    }
}

private struct PendingAndroidLaunch {
    let apk: URL
    let account: PlayerAccount
    let dataDirectory: URL
}

@MainActor
private enum AndroidSDKInstallCoordinator {
    private static var installation: Task<AndroidSDKPaths, Error>?

    static func install(
        at root: URL,
        progress: @escaping @MainActor @Sendable (GameLaunchStage, String, Double?) -> Void
    ) async throws -> AndroidSDKPaths {
        if let installation { return try await installation.value }
        let task = Task { @MainActor in
            try await AndroidSDKInstaller.install(at: root, progress: progress)
        }
        installation = task
        defer { installation = nil }
        return try await task.value
    }
}
