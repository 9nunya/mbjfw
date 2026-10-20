import AppKit

@MainActor
final class LauncherApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var library: GameLibrary?

    func applicationDidBecomeActive(_ notification: Notification) {
        library?.runtime.applicationBecameActive()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if library?.activeRuntime != nil { library?.focusGameWindow(); return false }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library,
              library.runtimes.values.contains(where: { $0.isGameRunning || $0.isLaunching || $0.isInstalling || $0.isStopping }) else { return .terminateNow }
        Task { @MainActor in
            await library.stopAllInstancesAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
