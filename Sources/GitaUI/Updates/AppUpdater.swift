import AppKit
import Combine
import Sparkle
import os

struct UpdaterDriverSnapshot: Equatable {
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
}

@MainActor
protocol UpdaterDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    func startUpdater()
    func checkForUpdates()
    func observeChanges(_ onChange: @escaping @MainActor (UpdaterDriverSnapshot) -> Void) -> AnyCancellable
}

/// Live Sparkle 2 driver wrapping `SPUStandardUpdaterController` and its KVO publishers.
@MainActor
final class SparkleUpdaterDriver: UpdaterDriver {
    private let controller: SPUStandardUpdaterController

    init(updaterDelegate: (any SPUUpdaterDelegate)?, userDriverDelegate: (any SPUStandardUserDriverDelegate)?) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: updaterDelegate, userDriverDelegate: userDriverDelegate)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func startUpdater() { controller.startUpdater() }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    func observeChanges(_ onChange: @escaping @MainActor (UpdaterDriverSnapshot) -> Void) -> AnyCancellable {
        let updater = controller.updater
        let emit: @MainActor () -> Void = {
            onChange(
                UpdaterDriverSnapshot(
                    canCheckForUpdates: updater.canCheckForUpdates,
                    automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
                    automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates))
        }
        var cancellables: Set<AnyCancellable> = []
        updater.publisher(for: \.canCheckForUpdates).sink { _ in emit() }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { _ in emit() }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { _ in emit() }.store(in: &cancellables)
        return AnyCancellable { cancellables.removeAll() }
    }
}

/// Ungated Sparkle 2 in-app updater for Gitā's official Developer ID build (`https://getgita.app/appcast.xml`).
/// Carries zero license headers and never touches Keychain; updates are verified with Ed25519 (`SUPublicEDKey`).
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(String)
        case failed(String)
    }

    nonisolated private static let log = Logger(subsystem: AppEnvironment.defaultBundleIdentifier, category: "updates")

    private var driver: (any UpdaterDriver)?
    private var driverObservation: AnyCancellable?
    private var hasAttemptedStart = false
    private var isSyncingFromDriver = false
    private var observers: [UUID: @MainActor () -> Void] = [:]

    private let driverFactory: @MainActor (AppUpdater) -> any UpdaterDriver
    private let officialBuildCheck: (URL) -> Bool
    private let feedOverrideProvider: @Sendable () -> String?
    private let activateApp: @MainActor () -> Void
    private let presentUnavailable: @MainActor () -> Void

    private(set) var isEnabled = false
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var state: State = .idle
    private(set) var availableVersion: String?
    private(set) var pendingVersion: String?

    /// Whether menu and About update triggers should be enabled (always on for unsigned copies so they explain why).
    var canRunUpdateAction: Bool {
        !isEnabled || canCheckForUpdates || availableVersion != nil || pendingVersion != nil
    }

    var automaticallyChecksForUpdates = true {
        didSet {
            guard !isSyncingFromDriver, isEnabled, let driver,
                driver.automaticallyChecksForUpdates != automaticallyChecksForUpdates
            else { return }
            driver.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            notifyObservers()
        }
    }

    var automaticallyDownloadsUpdates = false {
        didSet {
            guard !isSyncingFromDriver, isEnabled, let driver,
                driver.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates
            else { return }
            driver.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            notifyObservers()
        }
    }

    init(
        driverFactory: @escaping @MainActor (AppUpdater) -> any UpdaterDriver = { updater in
            SparkleUpdaterDriver(updaterDelegate: updater, userDriverDelegate: updater)
        },
        officialBuildCheck: @escaping (URL) -> Bool = { UpdateFeedPolicy.isOfficialBuild(bundleURL: $0) },
        feedOverrideProvider: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: UpdateFeedPolicy.feedOverrideKey)
        },
        activateApp: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        presentUnavailable: @escaping @MainActor () -> Void = AppUpdater.showUnavailableAlert
    ) {
        self.driverFactory = driverFactory
        self.officialBuildCheck = officialBuildCheck
        self.feedOverrideProvider = feedOverrideProvider
        self.activateApp = activateApp
        self.presentUnavailable = presentUnavailable
        super.init()
    }

    /// Starts Sparkle once on official signed Developer ID builds; never starts in dev, test, or headless runs.
    func start(environment: AppEnvironment = .current) {
        guard !isEnabled else { return }
        hasAttemptedStart = true
        guard !environment.isDevelopment, environment.startsServices, officialBuildCheck(environment.bundleURL) else {
            Self.log.notice("Not a signed release build: automatic updates are off")
            return
        }
        let driver = driverFactory(self)
        self.driver = driver
        driverObservation = driver.observeChanges { [weak self] snapshot in
            self?.applyDriverSnapshot(snapshot)
        }
        driver.startUpdater()
        isEnabled = true
        Self.log.info("Sparkle updater started for \(UpdateFeedPolicy.productionFeedURLString, privacy: .public)")
        applyDriverSnapshot(
            UpdaterDriverSnapshot(
                canCheckForUpdates: driver.canCheckForUpdates,
                automaticallyChecksForUpdates: driver.automaticallyChecksForUpdates,
                automaticallyDownloadsUpdates: driver.automaticallyDownloadsUpdates))
        lastUpdateCheckDate = driver.lastUpdateCheckDate
        notifyObservers()
    }

    /// Menu, Settings, and About "Check for Updates…" action.
    func checkForUpdates() {
        if !hasAttemptedStart { start() }
        activateApp()
        guard isEnabled, let driver else {
            presentUnavailable()
            return
        }
        if availableVersion == nil {
            state = .checking
            notifyObservers()
        }
        driver.checkForUpdates()
    }

    /// Brings Sparkle's window forward to install a pending or available update.
    func installAvailableUpdate() { checkForUpdates() }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func recordFoundVersion(_ version: String) {
        availableVersion = version
        pendingVersion = version
        state = .available(version)
        notifyObservers()
    }

    func recordNoUpdateFound() {
        availableVersion = nil
        pendingVersion = nil
        state = .upToDate
        notifyObservers()
    }

    func clearPendingVersion() {
        guard pendingVersion != nil else { return }
        pendingVersion = nil
        notifyObservers()
    }

    func handleScheduledUpdatePresentation(handledBySparkle: Bool, version: String) {
        if !handledBySparkle { recordFoundVersion(version) }
    }

    func recordUpdateCycleFinished(lastCheckDate: Date?, error: (any Error)?) {
        lastUpdateCheckDate = lastCheckDate
        if state == .checking {
            if let error, !Self.isBenignUpdateError(error) {
                state = .failed(error.localizedDescription)
            } else {
                state = .upToDate
            }
        }
        notifyObservers()
    }

    nonisolated static func isBenignUpdateError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else { return false }
        let noUpdate = Int(SUError.noUpdateError.rawValue)
        let canceled = Int(SUError.installationCanceledError.rawValue)
        return nsError.code == noUpdate || nsError.code == canceled
    }

    private func applyDriverSnapshot(_ snapshot: UpdaterDriverSnapshot) {
        isSyncingFromDriver = true
        defer { isSyncingFromDriver = false }
        var changed = false
        if canCheckForUpdates != snapshot.canCheckForUpdates {
            canCheckForUpdates = snapshot.canCheckForUpdates
            changed = true
        }
        if automaticallyChecksForUpdates != snapshot.automaticallyChecksForUpdates {
            automaticallyChecksForUpdates = snapshot.automaticallyChecksForUpdates
            changed = true
        }
        if automaticallyDownloadsUpdates != snapshot.automaticallyDownloadsUpdates {
            automaticallyDownloadsUpdates = snapshot.automaticallyDownloadsUpdates
            changed = true
        }
        if changed { notifyObservers() }
    }

    private func notifyObservers() {
        for handler in observers.values { handler() }
    }

    private static func showUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Updates are available in the official app")
        alert.informativeText = String(
            localized: "This copy isn’t the signed release from getgita.app, so it doesn’t update itself.")
        alert.runModal()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for _: SPUUpdater) -> String? {
        UpdateFeedPolicy.validatedFeedOverride(feedOverrideProvider())?.absoluteString
    }

    nonisolated func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { recordFoundVersion(item.displayVersionString) }
    }

    nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
        MainActor.assumeIsolated { recordNoUpdateFound() }
    }

    nonisolated func updater(_: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Self.log.error(
            "Downloading \(item.displayVersionString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
    }

    nonisolated func updater(_: SPUUpdater, didAbortWithError error: any Error) {
        guard !Self.isBenignUpdateError(error) else { return }
        Self.log.error("Update aborted: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            recordUpdateCycleFinished(lastCheckDate: updater.lastUpdateCheckDate, error: error)
        }
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { immediateFocus }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state _: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            handleScheduledUpdatePresentation(
                handledBySparkle: handleShowingUpdate, version: update.displayVersionString)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        MainActor.assumeIsolated { clearPendingVersion() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearPendingVersion() }
    }
}
