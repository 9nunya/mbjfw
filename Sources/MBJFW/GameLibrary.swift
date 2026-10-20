import Foundation
import SwiftUI

struct GameBuild: Codable, Identifiable, Equatable {
    var id: String
    var importedAt: Date
    var installed: Bool
    var metadata: APKMetadata?
    var originalFilename: String?
    var displayName: String { metadata.map { "Minecraft \($0.version)" } ?? originalFilename ?? id }
}

struct GameLaunchWindowRequest: Identifiable, Equatable {
    let id: UUID
    let accountID: UUID

    init(accountID: UUID) {
        id = UUID()
        self.accountID = accountID
    }
}

@MainActor
@Observable
final class GameLibrary {
    private(set) var builds: [GameBuild] = []
    private(set) var runtimes: [UUID: AndroidRuntimeManager] = [:]
    private(set) var progressWindowRequests: [GameLaunchWindowRequest] = []
    private var isImporting = false
    private var pendingLaunches: Set<UUID> = []
    private var launchValidationTasks: [UUID: Task<Void, Never>] = [:]
    private var activityMessage = ""

    private let defaults = UserDefaults.standard
    private let buildKey = "mbjfw.builds"
    private let selectionKey = "mbjfw.selectedBuild"
    let accounts = AccountStore()

    var runtime: AndroidRuntimeManager { runtime(for: accounts.selectedAccountID) }
    var activeRuntime: AndroidRuntimeManager? {
        if let selected = runtimes[accounts.selectedAccountID], selected.isGameRunning { return selected }
        return accounts.activeAccounts.compactMap { runtimes[$0.id] }.first(where: \.isGameRunning)
    }
    var selectedBuildID: String? { accounts.selectedAccount.selectedBuildID }
    var selectedBuild: GameBuild? { builds.first { $0.id == selectedBuildID } }
    var licenseRuntime: AndroidRuntimeManager? { runtimes.values.first(where: \.needsLicenseConsent) }
    var isWorking: Bool {
        isImporting || !pendingLaunches.isEmpty || runtimes.values.contains(where: { $0.isInstalling || $0.isLaunching })
    }

    init() {
        if let data = CatalogStore.shared.load(buildKey, defaults: defaults),
           let saved = try? JSONDecoder().decode([GameBuild].self, from: data) {
            builds = saved
        }
        if accounts.selectedAccount.selectedBuildID == nil,
           let legacySelection = defaults.string(forKey: selectionKey),
           builds.contains(where: { $0.id == legacySelection }) {
            accounts.setSelectedBuild(legacySelection, for: accounts.selectedAccountID)
        }
        migratePreviouslySelectedAPK()
    }

    func runtime(for accountID: UUID) -> AndroidRuntimeManager {
        if let runtime = runtimes[accountID] { return runtime }
        let runtime = AndroidRuntimeManager(settings: accounts.account(id: accountID)?.settings ?? .default)
        runtimes[accountID] = runtime
        return runtime
    }

    func isProfileBusy(_ accountID: UUID) -> Bool {
        let manager = runtime(for: accountID)
        return pendingLaunches.contains(accountID) || manager.isInstalling || manager.isLaunching || manager.isGameRunning || manager.isStopping
    }

    func isProfilePreparing(_ accountID: UUID) -> Bool { pendingLaunches.contains(accountID) }

    func updateSettings(_ settings: ProfileSettings, for accountID: UUID) {
        accounts.setSettings(settings, for: accountID)
        runtime(for: accountID).updateSettings(settings)
    }

    func setSelectedBuild(_ buildID: String?, for accountID: UUID) {
        guard buildID == nil || builds.contains(where: { $0.id == buildID }) else { return }
        accounts.setSelectedBuild(buildID, for: accountID)
        if accountID == accounts.selectedAccountID { defaults.set(buildID, forKey: selectionKey) }
    }

    func acceptSDKConsent() {
        let waiting = runtimes.values.filter(\.needsLicenseConsent)
        guard !waiting.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: "mbjfw.androidSDKConsentAccepted")
        for runtime in waiting { runtime.acceptLicenseAndInstall() }
    }

    func declineSDKConsent() {
        for runtime in runtimes.values where runtime.needsLicenseConsent { runtime.declineLicense() }
    }

    func archive(_ account: PlayerAccount) {
        guard !isProfileBusy(account.id) else {
            activityMessage = "Stop this profile before archiving it."
            return
        }
        accounts.archive(account)
    }

    func stopAllInstancesAndWait() async {
        let validations = Array(launchValidationTasks.values)
        for task in validations { task.cancel() }
        for task in validations { await task.value }
        let snapshot = Array(runtimes.values)
        for runtime in snapshot where runtime.isGameRunning || runtime.isLaunching || runtime.isInstalling || runtime.isStopping {
            await runtime.stopGameAndWait()
        }
    }

    func stopProfile(_ accountID: UUID) {
        launchValidationTasks[accountID]?.cancel()
        let manager = runtime(for: accountID)
        if manager.isInstalling { manager.cancelPreparation() }
        else { manager.stopGame() }
    }

    func focusGameWindow() { activeRuntime?.focusGameWindow() }

    var statusMessage: String {
        let active = runtimes.values.filter(\.isGameRunning).count
        if active > 1 { return "\(active) Minecraft profiles are running." }
        let selectedRuntime = runtime
        if selectedRuntime.isInstalling || selectedRuntime.isLaunching || selectedRuntime.isStopping || selectedRuntime.isGameRunning {
            return selectedRuntime.statusMessage
        }
        if !selectedRuntime.isReady { return selectedRuntime.statusMessage }
        if !activityMessage.isEmpty { return activityMessage }
        if let selectedBuild { return "\(selectedBuild.displayName) is ready to play." }
        return builds.isEmpty ? "Add a Bedrock APK to get started." : "Choose a build for this profile."
    }

    func selectBuild(_ id: String, for accountID: UUID? = nil) {
        setSelectedBuild(id, for: accountID ?? accounts.selectedAccountID)
    }

    func importAPK(_ source: URL) {
        guard !isImporting else { return }
        let targetAccountID = accounts.selectedAccountID
        guard let targetAccount = accounts.account(id: targetAccountID) else { return }
        guard source.pathExtension.lowercased() == "apk" else {
            activityMessage = "Choose an .apk file."
            return
        }
        isImporting = true
        activityMessage = "Importing \(source.lastPathComponent)…"
        Task { @MainActor in
            defer { isImporting = false }
            let hasScope = source.startAccessingSecurityScopedResource()
            defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
            do {
                let log = runtime(for: targetAccountID).paths.importLog
                let metadata = try await APKInspector.inspect(source, log: log)
                let id = metadata.sha256
                if let existing = builds.first(where: { $0.id == id || $0.metadata?.sha256 == id }) {
                    selectBuild(existing.id, for: targetAccountID)
                    activityMessage = "\(existing.displayName) is assigned to \(targetAccount.name)."
                    return
                }
                let destination = try apkURL(for: id)
                let staging = destination.appendingPathExtension("importing")
                if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                try await AndroidProcessRunner.run(
                    URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [source.path, staging.path],
                    environment: [:], logURL: log
                )
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(at: staging, to: destination)
                } else {
                    guard try FileDigest.sha256(destination) == id else { throw APKError.invalid }
                    try FileManager.default.removeItem(at: staging)
                }
                let build = GameBuild(id: id, importedAt: .now, installed: false, metadata: metadata, originalFilename: source.lastPathComponent)
                builds.insert(build, at: 0)
                let oldSelection = accounts.account(id: targetAccountID)?.selectedBuildID
                setSelectedBuild(id, for: targetAccountID)
                do { try persist() }
                catch {
                    builds.removeAll { $0.id == id }
                    setSelectedBuild(oldSelection, for: targetAccountID)
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                activityMessage = "\(build.displayName) is ready for \(targetAccount.name)."
            } catch {
                activityMessage = error.localizedDescription
            }
        }
    }

    func launch(for accountID: UUID? = nil) {
        guard let account = accounts.account(id: accountID ?? accounts.selectedAccountID), !account.archived else {
            activityMessage = "Restore this profile before starting it."
            return
        }
        guard !isProfileBusy(account.id) else { return }
        guard let buildID = account.selectedBuildID,
              let build = builds.first(where: { $0.id == buildID }) else {
            activityMessage = "Choose a Minecraft APK for \(account.name)."
            return
        }
        do {
            let manager = runtime(for: account.id)
            let directory = try accounts.emulatorDirectory(for: account)
            let apk = try apkURL(for: build.id, createParent: false)
            guard FileManager.default.fileExists(atPath: apk.path) else { throw LauncherError.apkMissing }
            progressWindowRequests.append(GameLaunchWindowRequest(accountID: account.id))
            pendingLaunches.insert(account.id)
            launchValidationTasks[account.id] = Task { @MainActor in
                defer {
                    pendingLaunches.remove(account.id)
                    launchValidationTasks.removeValue(forKey: account.id)
                }
                do {
                    let metadata = try await APKInspector.inspect(apk, log: manager.paths.importLog)
                    try Task.checkCancellation()
                    if let expected = build.metadata, expected.sha256 != metadata.sha256 { throw APKError.invalid }
                    if let index = builds.firstIndex(where: { $0.id == build.id }) {
                        builds[index].metadata = metadata
                        try persist()
                    }
                    manager.launch(apk: apk, account: account, dataDirectory: directory)
                } catch is CancellationError {
                } catch { activityMessage = error.localizedDescription }
            }
        } catch {
            activityMessage = error.localizedDescription
        }
    }

    func remove(_ build: GameBuild) {
        let pendingUse = pendingLaunches.contains { accountID in
            accounts.account(id: accountID)?.selectedBuildID == build.id
        }
        guard !pendingUse, !runtimes.values.contains(where: { $0.activeBuildID == build.id && ($0.isGameRunning || $0.isLaunching || $0.isInstalling) }) else {
            activityMessage = "Stop every profile using this APK before removing it."
            return
        }
        do {
            let apk = try apkURL(for: build.id, createParent: false)
            let quarantine = apk.appendingPathExtension("removing")
            if FileManager.default.fileExists(atPath: apk.path) { try FileManager.default.moveItem(at: apk, to: quarantine) }
            let oldBuilds = builds
            let oldSelections = Dictionary(uniqueKeysWithValues: accounts.accounts.map { ($0.id, $0.selectedBuildID) })
            builds.removeAll { $0.id == build.id }
            do {
                try accounts.clearBuildSelection(build.id)
                try persist()
            }
            catch {
                builds = oldBuilds
                for (accountID, selection) in oldSelections { accounts.setSelectedBuild(selection, for: accountID) }
                if FileManager.default.fileExists(atPath: quarantine.path) { try? FileManager.default.moveItem(at: quarantine, to: apk) }
                throw error
            }
            if FileManager.default.fileExists(atPath: quarantine.path) { try FileManager.default.removeItem(at: quarantine) }
            activityMessage = "Removed \(build.displayName)."
        } catch {
            activityMessage = error.localizedDescription
        }
    }

    private func apkURL(for id: String, createParent: Bool = true) throws -> URL {
        let safeID = id.replacingOccurrences(of: "/", with: "-")
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appending(path: "MBJFW/apks")
        if createParent { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appending(path: "\(safeID).apk")
    }

    private func migratePreviouslySelectedAPK() {
        guard let legacyPath = defaults.string(forKey: "mbjfw.enginePath") else { return }
        let source = URL(fileURLWithPath: legacyPath)
        guard source.pathExtension.lowercased() == "apk",
              let build = builds.first(where: { $0.id == source.deletingPathExtension().lastPathComponent }),
              let destination = try? apkURL(for: build.id),
              !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(builds)
        try CatalogStore.shared.save(data, key: buildKey, defaults: defaults)
    }
}

enum LauncherError: LocalizedError {
    case apkMissing

    var errorDescription: String? {
        switch self {
        case .apkMissing:
            "The imported APK is missing. Import it again."
        }
    }
}
