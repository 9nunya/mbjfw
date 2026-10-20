import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(GameLibrary.self) private var library
    @State private var resizeMessage: String?
    @State private var backupFiles: [URL] = []
    @State private var backupStatus: String?
    @State private var importingBackup = false

    private var accountID: UUID { library.accounts.selectedAccountID }
    private var runtime: AndroidRuntimeManager { library.runtime(for: accountID) }

    private func setting<Value>(_ keyPath: WritableKeyPath<ProfileSettings, Value>) -> Binding<Value> {
        Binding(
            get: { library.accounts.selectedAccount.settings[keyPath: keyPath] },
            set: { value in
                var settings = library.accounts.selectedAccount.settings
                settings[keyPath: keyPath] = value
                library.updateSettings(settings, for: accountID)
            }
        )
    }

    private var buildSelection: Binding<String?> {
        Binding(
            get: { library.accounts.selectedAccount.selectedBuildID },
            set: { library.setSelectedBuild($0, for: accountID) }
        )
    }

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Name", value: library.accounts.selectedAccount.name)
                Picker("Minecraft APK", selection: buildSelection) {
                    Text("None").tag(String?.none)
                    ForEach(library.builds) { build in
                        Text(build.displayName).tag(Optional(build.id))
                    }
                }
                Text("APK assignment and Android settings are saved separately for each profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Graphics") {
                Picker("Renderer", selection: setting(\.graphicsMode)) {
                    Text("Mac GPU").tag("host")
                    Text("Software compatibility").tag("software")
                }
                Text("Renderer changes apply the next time this profile starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Game display") {
                Toggle("Match Android display to game window", isOn: setting(\.displayFollowsWindow))
                Picker("Resolution", selection: setting(\.guestResolution)) {
                    Text("1280 × 720").tag("1280x720")
                    Text("1600 × 900").tag("1600x900")
                    Text("1920 × 1080").tag("1920x1080")
                }
                Picker("Interface scale", selection: setting(\.guestDensity)) {
                    Text("Compact").tag("120")
                    Text("Default").tag("160")
                    Text("Large").tag("200")
                }
                Button("Apply to Running Game") {
                    let resolution = library.accounts.selectedAccount.settings.guestResolution
                    let dimensions = resolution.split(separator: "x").compactMap { Int($0) }
                    guard dimensions.count == 2 else { return }
                    Task { @MainActor in
                        do {
                            try await runtime.applyDisplay(width: dimensions[0], height: dimensions[1])
                            resizeMessage = "Android display set to \(resolution)."
                        } catch { resizeMessage = error.localizedDescription }
                    }
                }
                .disabled(!runtime.isGameRunning)
                if let resizeMessage {
                    Text(resizeMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Android changes its display mode to the nearest supported resolution while the Mac window remains freely resizable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Performance") {
                Picker("Memory", selection: setting(\.guestMemory)) {
                    Text("3 GB").tag(3072)
                    Text("4 GB").tag(4096)
                    Text("6 GB").tag(6144)
                    Text("8 GB").tag(8192)
                }
                Picker("Processor cores", selection: setting(\.guestCores)) {
                    Text("2 cores").tag(2)
                    Text("4 cores").tag(4)
                    Text("6 cores").tag(6)
                }
                Text("Memory and processor changes apply when this profile starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                Toggle("Game audio", isOn: Binding(
                    get: { !library.accounts.selectedAccount.settings.disableGameAudio },
                    set: { setting(\.disableGameAudio).wrappedValue = !$0 }
                ))
                Text("Audio is routed through Android to your Mac output.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Runtime") {
                LabeledContent("Android", value: runtime.isReady ? RuntimeArchitecture.current.runtimeDescription : "Not installed")
                LabeledContent("Renderer", value: library.accounts.selectedAccount.settings.graphicsMode == "software" ? "Software" : "Mac GPU · Vulkan")
                LabeledContent("Game data", value: "Separate for each profile")
                if let failure = CatalogStore.shared.failure ?? library.accounts.persistenceError {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    LabeledContent("Library", value: "Saved on this Mac")
                }
                if runtime.isGameRunning {
                    Button("Restore Optional Android Apps") {
                        Task { @MainActor in
                            do {
                                let account = library.accounts.selectedAccount
                                let folder = try library.accounts.emulatorDirectory(for: account)
                                let count = try await runtime.restoreOptionalApps(for: account, dataDirectory: folder)
                                backupStatus = "Restored \(count) apps. Restart Android to apply the change."
                            } catch { backupStatus = error.localizedDescription }
                        }
                    }
                }
            }

            Section("Profile data") {
                Button("Back Up Selected Profile…") {
                    Task { @MainActor in
                        do {
                            await runtime.stopGameAndWait()
                            let account = library.accounts.selectedAccount
                            let folder = try library.accounts.emulatorDirectory(for: account)
                            let backup = try await ProfileBackupStore.create(account: account, source: folder)
                            backupStatus = "Verified backup saved: \(backup.lastPathComponent)"
                            refreshBackups()
                        } catch { backupStatus = error.localizedDescription }
                    }
                }
                .disabled(runtime.isInstalling || runtime.isStopping || runtime.isLaunching)

                if !backupFiles.isEmpty {
                    ForEach(backupFiles, id: \.path) { backup in
                        HStack {
                            Text(backup.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button("Restore") { restore(backup) }
                                .disabled(runtime.isInstalling || runtime.isStopping || runtime.isLaunching)
                        }
                    }
                }
                Button("Choose Backup File…") { importingBackup = true }
                if let backupStatus {
                    Text(backupStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if runtime.isGameRunning || runtime.isLaunching {
                    Button("Stop Game and Android", role: .destructive) { runtime.stopGame() }
                        .disabled(runtime.isStopping)
                }
                Text("Worlds remain in this profile when you stop the game.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refreshBackups() }
        .onChange(of: accountID) { _, _ in refreshBackups(); resizeMessage = nil; backupStatus = nil }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            Task { @MainActor in
                do {
                    let files = try result.get()
                    guard let archive = files.first else { throw ProfileBackupError.unverifiedArchive }
                    let account = library.accounts.selectedAccount
                    await library.runtime(for: account.id).stopGameAndWait()
                    let folder = try library.accounts.emulatorDirectory(for: account)
                    let recovery = try await ProfileBackupStore.restore(archive: archive, account: account, destination: folder)
                    backupStatus = recovery.map { "Restored. Previous data kept at \($0.path)." } ?? "Profile restored."
                    refreshBackups()
                } catch { backupStatus = error.localizedDescription }
            }
        }
    }

    private func restore(_ backup: URL) {
        Task { @MainActor in
            do {
                let account = library.accounts.selectedAccount
                await library.runtime(for: account.id).stopGameAndWait()
                let folder = try library.accounts.emulatorDirectory(for: account)
                let recovery = try await ProfileBackupStore.restore(archive: backup, account: account, destination: folder)
                backupStatus = recovery.map { "Restored. Previous data kept at \($0.path)." } ?? "Profile restored."
                refreshBackups()
            } catch { backupStatus = error.localizedDescription }
        }
    }

    private func refreshBackups() {
        let account = library.accounts.selectedAccount
        let directory = (try? library.accounts.accountDirectory(for: account)) ?? URL(fileURLWithPath: "/")
        backupFiles = (try? ProfileBackupStore.list(for: account, accountDirectory: directory)) ?? []
    }
}
