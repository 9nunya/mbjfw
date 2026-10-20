import SwiftUI
import UniformTypeIdentifiers

struct AccountsView: View {
    @Environment(GameLibrary.self) private var library
    @State private var addingAccount = false
    @State private var accountName = ""
    @State private var choosingAPK = false

    private var selection: Binding<UUID?> {
        Binding(
            get: { library.accounts.selectedAccountID },
            set: { id in
                guard let id,
                      let account = library.accounts.activeAccounts.first(where: { $0.id == id }) else { return }
                library.accounts.select(account)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(library.accounts.activeAccounts) { account in
                    ProfileRow(account: account)
                        .tag(account.id)
                        .contextMenu {
                            if library.accounts.activeAccounts.count > 1 {
                                Button("Archive Profile", role: .destructive) { library.archive(account) }
                                    .disabled(isBusy(account))
                            }
                        }
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Each profile has its own Minecraft sign-in and saved worlds.")
            }

            if !library.accounts.archivedAccounts.isEmpty {
                Section("Archived") {
                    ForEach(library.accounts.archivedAccounts) { account in
                        HStack {
                            Label(account.name, systemImage: "archivebox")
                            Spacer()
                            Button("Restore") { library.accounts.restore(account) }
                                .buttonStyle(.borderless)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Profile…", systemImage: "plus") { addingAccount = true }
            }
            ToolbarItem {
                Button("Import APK…", systemImage: "square.and.arrow.down") { choosingAPK = true }
            }
        }
        .sheet(isPresented: $addingAccount) {
            NavigationStack {
                Form {
                    TextField("Profile name", text: $accountName)
                }
                .formStyle(.grouped)
                .navigationTitle("Add Profile")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { addingAccount = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            library.accounts.add(name: accountName)
                            accountName = ""
                            addingAccount = false
                        }
                        .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(minWidth: 360, minHeight: 150)
        }
        .fileImporter(isPresented: $choosingAPK, allowedContentTypes: [.init(filenameExtension: "apk") ?? .data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            library.importAPK(url)
        }
    }

    private func isBusy(_ account: PlayerAccount) -> Bool {
        library.isProfileBusy(account.id)
    }
}

private struct ProfileRow: View {
    @Environment(GameLibrary.self) private var library
    let account: PlayerAccount

    private var runtime: AndroidRuntimeManager { library.runtime(for: account.id) }
    private var selection: Binding<String?> {
        Binding(
            get: { account.selectedBuildID },
            set: { library.setSelectedBuild($0, for: account.id) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(account.name, systemImage: "person.crop.circle")
                    .fontWeight(.medium)
                Spacer()
                status
                if library.isProfilePreparing(account.id) || runtime.isGameRunning || runtime.isLaunching || runtime.isInstalling {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { library.stopProfile(account.id) }
                        .labelStyle(.iconOnly)
                        .help("Stop \(account.name)")
                        .disabled(runtime.isStopping)
                } else {
                    Button("Start", systemImage: "play.fill") { library.launch(for: account.id) }
                        .labelStyle(.iconOnly)
                        .help("Start \(account.name)")
                        .disabled(account.selectedBuildID == nil || library.isProfileBusy(account.id))
                }
            }
            Picker("Minecraft APK", selection: selection) {
                Text("Choose APK…").tag(String?.none)
                ForEach(library.builds) { build in
                    Text(build.displayName).tag(Optional(build.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(runtime.isGameRunning || runtime.isLaunching || runtime.isInstalling)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var status: some View {
        if runtime.isGameRunning {
            Label("Running", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if library.isProfilePreparing(account.id) || runtime.isInstalling || runtime.isLaunching {
            ProgressView().controlSize(.small).help(runtime.statusMessage)
        } else if runtime.isReady {
            Text("Stopped").font(.caption).foregroundStyle(.tertiary)
        } else {
            Text("Not installed").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
