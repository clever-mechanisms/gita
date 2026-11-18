import AppKit
import Darwin
import GitaCore

/// Starts Gita. The `GitaApp` executable only calls `run()`.
public enum AppLauncher {
    @MainActor public static func run() -> Never {
        if let status = GitRebaseEditor.handleInvocation(arguments: CommandLine.arguments) { exit(status) }
        AppLanguage.configureForLaunch()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }
}
