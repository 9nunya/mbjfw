import SwiftUI

struct LauncherView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow
    @State private var tab: LauncherTab? = .overview

    private var selectedTab: LauncherTab { tab ?? .overview }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $tab) {
                    Section("MBJFW") {
                        ForEach(LauncherTab.allCases) { item in
                            Label(item.rawValue, systemImage: item.symbol)
                                .tag(item)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: library.runtime.isReady ? "checkmark.circle" : "circle.dashed")
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text(library.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .navigationTitle("MBJFW")
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
        } detail: {
            Group {
                switch selectedTab {
                case .overview: OverviewView(tab: Binding(get: { selectedTab }, set: { tab = $0 }))
                case .accounts: AccountsView()
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selectedTab.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { library.licenseRuntime != nil },
            set: { if !$0 { library.declineSDKConsent() } }
        )) {
            SDKConsentView()
                .environment(library)
        }
        .onChange(of: library.progressToken) { _, _ in
            openWindow(id: "game")
        }
    }
}
