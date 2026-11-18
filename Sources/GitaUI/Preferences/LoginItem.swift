import AppKit
import ServiceManagement

/// Open at Login. Reading status never registers the app or opens System Settings.
@MainActor
enum LoginItem {
    enum Status: Equatable { case enabled, requiresApproval, disabled, unavailable }

    /// Launch flags of scripted or development runs, which never show the offer.
    private static let excludedFlags: Set<String> = ["--background", "--replay", "--debug", "--development"]

    /// Only an installed copy (in an Applications folder, not run from a quarantine translocation, with the app's
    /// identifier) registers itself: a build in a working copy never adds a login item.
    static func isInstalledCopy(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        let path = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return bundleIdentifier == AppEnvironment.defaultBundleIdentifier && path.hasSuffix(".app")
            && (folder == "/Applications" || folder.hasSuffix("/Applications")) && !path.contains("/AppTranslocation/")
    }
    static var isInstalledCopy: Bool {
        isInstalledCopy(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static var status: Status {
        guard isInstalledCopy else { return .unavailable }
        return status(SMAppService.mainApp.status)
    }
    static func status(_ service: SMAppService.Status) -> Status {
        switch service {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        // An installed app that was never registered can read as notFound (ad-hoc signed builds); registering
        // still works, so it is offered like notRegistered.
        case .notFound: .disabled
        @unknown default: .unavailable
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let current = status
        guard current != .unavailable else { throw Unavailable() }
        if enabled {
            guard current == .disabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard current == .enabled || current == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        guard isInstalledCopy else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether the main window may offer Open at Login now: once, to an interactive release launch that is not
    /// registered yet.
    static func shouldOffer(environment: AppEnvironment) -> Bool {
        offerAllowed(
            arguments: environment.arguments, isDevelopment: environment.isDevelopment,
            buildConfiguration: Bundle.main.object(forInfoDictionaryKey: "GitaBuildConfiguration") as? String,
            answered: Preference.loginItemOfferAnswered.bool(environment.defaults))
            && !wasLaunchedAtLogin && status == .disabled
    }

    static func offerAllowed(
        arguments: [String], isDevelopment: Bool, buildConfiguration: String?, answered: Bool
    )
        -> Bool
    {
        guard !isDevelopment, buildConfiguration != "debug", !answered else { return false }
        return !arguments.dropFirst().contains { argument in
            guard argument.hasPrefix("--") else { return false }
            let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            return excludedFlags.contains(flag)
        }
    }

    static func answerOffer(defaults: UserDefaults) {
        if !Preference.loginItemOfferAnswered.bool(defaults) { Preference.loginItemOfferAnswered.set(true, defaults) }
    }

    /// Read during applicationDidFinishLaunching while the launch event is current.
    static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private struct Unavailable: LocalizedError {
        var errorDescription: String? {
            String(
                localized:
                    "Open at Login is unavailable for this copy of Gitā. Use the installed app in Applications.")
        }
    }
}
