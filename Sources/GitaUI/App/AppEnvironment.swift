import AppKit

/// What differs between the installed app, a development build and a test host: the settings domain, the launch
/// arguments, the app's identity and whether process-wide services start. Built once at launch and handed to the
/// shell, so both the release and the development paths run (and are tested) as plain code.
@MainActor
struct AppEnvironment {
    nonisolated static let defaultBundleIdentifier = "dev.clevermechanisms.Gita"
    /// Development runs keep their own settings domain so they never change the installed app's settings.
    nonisolated static let developmentSuite = "dev.clevermechanisms.Gita.development"
    nonisolated static let defaultURLScheme = "gita"

    /// A development build: its own settings domain, no single-instance hand-off, no saved window frame, no first
    /// run guide and no login item offer.
    var isDevelopment: Bool
    var defaults: UserDefaults
    var arguments: [String]
    var bundleIdentifier: String
    var bundleURL: URL
    var urlScheme: String
    /// Notifications, agent scanning, the login-shell lookup and other process-wide services. Off in test hosts.
    var startsServices: Bool
    /// The bar the menu bar item lives in (a private bar in test hosts).
    var statusBar: NSStatusBar
    /// Quitting, alerts, the pasteboard and other effects outside the shell's own windows.
    var system = AppSystemHooks()
    /// On-demand repository storage & health cache (zero idle CPU, cancels scans on window close).
    var storageStore = StorageStore()

    static let current = Self(
        isDevelopment: compiledForDevelopment, defaults: Preference.store, arguments: CommandLine.arguments,
        bundle: .main, startsServices: true, statusBar: .system)

    init(
        isDevelopment: Bool, defaults: UserDefaults, arguments: [String], bundle: Bundle, startsServices: Bool,
        statusBar: NSStatusBar
    ) {
        self.isDevelopment = isDevelopment
        self.defaults = defaults
        self.arguments = arguments
        bundleIdentifier = bundle.bundleIdentifier ?? Self.defaultBundleIdentifier
        bundleURL = bundle.bundleURL
        urlScheme = Self.urlScheme(in: bundle) ?? Self.defaultURLScheme
        self.startsServices = startsServices
        self.statusBar = statusBar
    }

    /// The one compile-time switch: everything else reads `isDevelopment`.
    nonisolated static var compiledForDevelopment: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    nonisolated static func settings(development: Bool) -> UserDefaults {
        development ? UserDefaults(suiteName: developmentSuite) ?? .standard : .standard
    }

    /// `--repository PATH` on the command line.
    var commandLineRepository: URL? {
        guard let index = arguments.firstIndex(of: "--repository"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func urlScheme(in bundle: Bundle) -> String? {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first
    }
}
