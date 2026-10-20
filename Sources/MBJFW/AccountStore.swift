import Foundation
import SwiftUI

struct PlayerAccount: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var archived: Bool
    var selectedBuildID: String?
    var settings: ProfileSettings

    init(id: UUID, name: String, archived: Bool = false, selectedBuildID: String? = nil, settings: ProfileSettings = .default) {
        self.id = id
        self.name = name
        self.archived = archived
        self.selectedBuildID = selectedBuildID
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case id, name, archived, selectedBuildID, settings }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        selectedBuildID = try values.decodeIfPresent(String.self, forKey: .selectedBuildID)
        settings = try values.decodeIfPresent(ProfileSettings.self, forKey: .settings) ?? .legacyDefaults
    }
}

struct ProfileSettings: Codable, Equatable {
    var graphicsMode: String
    var guestResolution: String
    var guestDensity: String
    var guestMemory: Int
    var guestCores: Int
    var disableGameAudio: Bool
    var displayFollowsWindow: Bool

    static let `default` = ProfileSettings(
        graphicsMode: "host", guestResolution: "1280x720", guestDensity: "160",
        guestMemory: 4096, guestCores: 4, disableGameAudio: false, displayFollowsWindow: true
    )

    static var legacyDefaults: ProfileSettings {
        let defaults = UserDefaults.standard
        return ProfileSettings(
            graphicsMode: defaults.string(forKey: "graphicsMode") ?? "host",
            guestResolution: defaults.string(forKey: "guestResolution") ?? "1280x720",
            guestDensity: defaults.string(forKey: "guestDensity") ?? "160",
            guestMemory: defaults.integer(forKey: "guestMemory") == 0 ? 4096 : defaults.integer(forKey: "guestMemory"),
            guestCores: defaults.integer(forKey: "guestCores") == 0 ? 4 : defaults.integer(forKey: "guestCores"),
            disableGameAudio: defaults.bool(forKey: "disableGameAudio"),
            displayFollowsWindow: defaults.object(forKey: "displayFollowsWindow") as? Bool ?? true
        )
    }
}

@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [PlayerAccount]
    var selectedAccountID: UUID

    private let defaults = UserDefaults.standard
    private let accountsKey = "mbjfw.accounts"
    private let selectedKey = "mbjfw.selectedAccount"

    init() {
        let saved = CatalogStore.shared.load(accountsKey, defaults: defaults).flatMap {
            try? JSONDecoder().decode([PlayerAccount].self, from: $0)
        } ?? []
        var initial = saved.isEmpty ? [PlayerAccount(id: UUID(), name: "Player 1")] : saved
        if initial.allSatisfy(\.archived) { initial[0].archived = false }
        accounts = initial
        selectedAccountID = defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)) ?? initial[0].id
        if saved.isEmpty { try? persist() }
        if !initial.contains(where: { $0.id == selectedAccountID && !$0.archived }) {
            selectedAccountID = initial.first(where: { !$0.archived })?.id ?? initial[0].id
            defaults.set(selectedAccountID.uuidString, forKey: selectedKey)
        }
    }

    var selectedAccount: PlayerAccount {
        accounts.first { $0.id == selectedAccountID && !$0.archived } ?? accounts.first(where: { !$0.archived }) ?? accounts[0]
    }

    var activeAccounts: [PlayerAccount] { accounts.filter { !$0.archived } }
    var archivedAccounts: [PlayerAccount] { accounts.filter(\.archived) }

    func select(_ account: PlayerAccount) {
        guard !account.archived else { return }
        selectedAccountID = account.id
        defaults.set(account.id.uuidString, forKey: selectedKey)
    }

    func account(id: UUID) -> PlayerAccount? { accounts.first { $0.id == id } }

    func setSelectedBuild(_ buildID: String?, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let previous = accounts[index].selectedBuildID
        accounts[index].selectedBuildID = buildID
        do { try persist() }
        catch { accounts[index].selectedBuildID = previous; persistenceError = error.localizedDescription }
    }

    func setSettings(_ settings: ProfileSettings, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }), accounts[index].settings != settings else { return }
        let previous = accounts[index].settings
        accounts[index].settings = settings
        do { try persist() }
        catch { accounts[index].settings = previous; persistenceError = error.localizedDescription }
    }

    func clearBuildSelection(_ buildID: String) throws {
        let previous = accounts
        for index in accounts.indices where accounts[index].selectedBuildID == buildID {
            accounts[index].selectedBuildID = nil
        }
        do { try persist() } catch { accounts = previous; persistenceError = error.localizedDescription; throw error }
    }

    func add(name: String) {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        let account = PlayerAccount(id: UUID(), name: label)
        let previousSelection = selectedAccountID
        accounts.append(account)
        select(account)
        do { try persist() }
        catch {
            accounts.removeAll { $0.id == account.id }
            selectedAccountID = previousSelection
            defaults.set(previousSelection.uuidString, forKey: selectedKey)
            persistenceError = error.localizedDescription
        }
    }

    func rename(_ account: PlayerAccount, to name: String) {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let index = accounts.firstIndex(of: account) else { return }
        let previous = accounts[index]
        accounts[index].name = label
        do { try persist() } catch { accounts[index] = previous; persistenceError = error.localizedDescription }
    }

    func archive(_ account: PlayerAccount) {
        guard accounts.filter({ !$0.archived }).count > 1,
              let index = accounts.firstIndex(of: account) else { return }
        let previousSelection = selectedAccountID
        accounts[index].archived = true
        if selectedAccountID == account.id,
           let replacement = accounts.first(where: { !$0.archived }) { select(replacement) }
        do { try persist() } catch {
            accounts[index].archived = false
            selectedAccountID = previousSelection
            defaults.set(previousSelection.uuidString, forKey: selectedKey)
            persistenceError = error.localizedDescription
        }
    }

    func restore(_ account: PlayerAccount) {
        guard let index = accounts.firstIndex(of: account) else { return }
        accounts[index].archived = false
        do { try persist() } catch { accounts[index].archived = true; persistenceError = error.localizedDescription }
    }

    func dataDirectory(for account: PlayerAccount) throws -> URL {
        let directory = try appSupportDirectory().appending(path: "MBJFW/accounts/\(account.id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func emulatorDirectory(for account: PlayerAccount) throws -> URL {
        let directory = try dataDirectory(for: account).appending(path: "android-avd")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func accountDirectory(for account: PlayerAccount) throws -> URL {
        try dataDirectory(for: account)
    }

    private func appSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private(set) var persistenceError: String?

    private func persist() throws {
        let data = try JSONEncoder().encode(accounts)
        do {
            try CatalogStore.shared.save(data, key: accountsKey, defaults: defaults)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            throw error
        }
    }
}
