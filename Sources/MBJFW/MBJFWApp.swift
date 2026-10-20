import SwiftUI

@main
struct MBJFWApp: App {
    @NSApplicationDelegateAdaptor(LauncherApplicationDelegate.self) private var delegate
    @State private var library = GameLibrary()

    var body: some Scene {
        WindowGroup {
            LauncherView()
                .environment(library)
                .onAppear { delegate.library = library }
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Show Game") { library.focusGameWindow() }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(library.activeRuntime == nil)
                Button("Show Launcher") { library.runtime.showLauncherWindow() }
                    .keyboardShortcut("1", modifiers: .command)
            }
        }

        WindowGroup("Bedrock", id: "game", for: UUID.self) { $accountID in
            if let accountID {
                GameWindowView(accountID: accountID).environment(library)
            } else {
                ContentUnavailableView("Choose a Profile", systemImage: "person.crop.circle")
                    .frame(minWidth: 560, minHeight: 400)
            }
        }
        .defaultSize(width: 1024, height: 640)
        .restorationBehavior(.disabled)
    }
}
