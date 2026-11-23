import AppKit
import Foundation
import ServiceManagement
import Testing

@testable import GitaUI

@Suite("Preferences store")
@MainActor
struct PreferencesStoreTests {
    @Test func readsDefaultsBeforeAndAfterRegistering() {
        let settings = AppTestDefaults()
        let defaults = settings.defaults
        defaults.removeObject(forKey: Preference.providerRefresh.rawValue)
        #expect(Preference.providerRefresh.bool(defaults))
        #expect(!Preference.notifications.bool(defaults))
        #expect(Preference.historyZoomPercent.int(defaults) == HistoryZoom.actual)
        #expect(Preference.theme.string(defaults) == "system")
        #expect(Preference.recentRepositories.strings(defaults).isEmpty)
        Preference.registerDefaults(in: defaults)
        #expect(defaults.string(forKey: Preference.settingsPane.rawValue) == "general")
        #expect(Preference.allCases.allSatisfy { defaults.object(forKey: $0.rawValue) != nil })
    }

    @Test func settingAPreferencePostsItsKey() throws {
        let settings = AppTestDefaults()
        let received = AppBox<Preference?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: nil
        ) { note in
            let preference = Preference(changed: note)
            MainActor.assumeIsolated { if preference == .graphLines { received.value = preference } }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        Preference.graphLines.set("angled", settings.defaults)
        #expect(received.value == .graphLines)
        #expect(Preference.graphLines.string(settings.defaults) == "angled")
        #expect(Preference(changed: Notification(name: .gitaPreferenceChanged)) == nil)
    }

    @Test func zoomStaysWithinItsRange() {
        #expect(HistoryZoom.clamped(0) == HistoryZoom.actual)
        #expect(HistoryZoom.clamped(500) == HistoryZoom.range.upperBound)
        #expect(HistoryZoom.zoomedIn(155) == HistoryZoom.range.upperBound)
        #expect(HistoryZoom.zoomedOut(85) == HistoryZoom.range.lowerBound)
        #expect(HistoryZoom.canZoomIn(150) && !HistoryZoom.canZoomIn(160))
        #expect(HistoryZoom.canZoomOut(90) && !HistoryZoom.canZoomOut(80))
        #expect(HistoryZoom.all == [80, 90, 100, 110, 120, 130, 140, 150, 160])
        #expect(HistoryZoom.bounded(0) == HistoryZoom.range.lowerBound)
        #expect(HistoryZoom.bounded(500) == HistoryZoom.range.upperBound)
        #expect(HistoryZoom.bounded(120) == 120)
        #expect(HistoryZoom.shown(170) == HistoryZoom.actual)
        #expect(HistoryZoom.shown(90) == 90)
        #expect(HistoryZoom.step == 10)
    }

    @Test func appearanceChoices() {
        #expect(AppearanceChoice(stored: 9) == .system)
        #expect(AppearanceChoice.system.appearance == nil)
        #expect(AppearanceChoice.light.appearance?.name == .aqua)
        #expect(AppearanceChoice(stored: 2).appearance?.name == .darkAqua)
    }
}

@Suite("Preferences relaunch tickets")
struct PreferencesRelaunchTicketTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func store(_ settings: AppTestDefaults, clock: Clock, pid: Int32 = 4_242) -> RelaunchTicketStore {
        RelaunchTicketStore(defaults: settings.defaults, processIdentifier: pid, now: { clock.now })
    }

    @Test func aTicketIsPendingForAShortWhile() throws {
        let settings = AppTestDefaults()
        let clock = Clock()
        let store = store(settings, clock: clock)
        let ticket = try #require(store.begin())
        #expect(store.isPending(ticket))
        clock.now += 60
        #expect(!store.isPending(ticket))
    }

    @Test func theReplacementTakesOverWithItsToken() throws {
        let settings = AppTestDefaults()
        let clock = Clock()
        let ticket = try #require(store(settings, clock: clock).begin())
        let replacement = store(settings, clock: clock, pid: 7)
        let arguments = ["Gita", RelaunchTicketStore.argument, ticket.token.uuidString]
        #expect(replacement.pending(arguments: arguments) == ticket)
        #expect(replacement.pending(arguments: ["Gita", RelaunchTicketStore.argument, UUID().uuidString]) == nil)
        #expect(replacement.pending(arguments: ["Gita", RelaunchTicketStore.argument]) == nil)
        #expect(store(settings, clock: clock).pending(arguments: arguments) == nil)
    }

    @Test func queuedRequestsAreHandedOverOnce() throws {
        let settings = AppTestDefaults()
        let clock = Clock()
        let store = store(settings, clock: clock)
        let ticket = try #require(store.begin())
        let folder = URL(fileURLWithPath: "/tmp/repo")
        let link = try #require(URL(string: "gita://open/history"))
        let foreign = try #require(URL(string: "https://example.invalid"))
        #expect(store.queue([folder, link, foreign, folder], for: ticket))
        #expect(try store.consume(ticket) == [folder, link])
        #expect(throws: RelaunchTicketStore.InvalidTicket.self) { try store.consume(ticket) }
    }

    @Test func tooManyRequestsCannotBeQueued() throws {
        let settings = AppTestDefaults()
        let store = store(settings, clock: Clock())
        let ticket = try #require(store.begin())
        let urls = (0..<40).map { URL(fileURLWithPath: "/tmp/repo\($0)") }
        #expect(!store.queue(urls, for: ticket))
        store.cancel(ticket)
        #expect(!store.isPending(ticket))
        #expect(!store.queue([], for: ticket))
    }

    @Test func aTamperedTicketIsRefused() throws {
        let settings = AppTestDefaults()
        let store = store(settings, clock: Clock())
        let ticket = try #require(store.begin())
        var tampered = ticket
        tampered.urls = ["not a url \u{0}"]
        settings.defaults.set(try JSONEncoder().encode(tampered), forKey: RelaunchTicketStore.key)
        #expect(throws: RelaunchTicketStore.InvalidTicket.self) { try store.consume(ticket) }
    }
}

@Suite("Preferences login item and language")
@MainActor
struct PreferencesLoginItemTests {
    @Test func onlyAnInstalledCopyRegisters() {
        let id = AppEnvironment.defaultBundleIdentifier
        #expect(
            LoginItem.isInstalledCopy(
                bundleURL: URL(fileURLWithPath: "/Applications/Gita.app"), bundleIdentifier: id))
        #expect(
            LoginItem.isInstalledCopy(
                bundleURL: URL(fileURLWithPath: "/Users/x/Applications/Gita.app"), bundleIdentifier: id))
        #expect(!LoginItem.isInstalledCopy(bundleURL: URL(fileURLWithPath: "/tmp/Gita.app"), bundleIdentifier: id))
        #expect(
            !LoginItem.isInstalledCopy(
                bundleURL: URL(fileURLWithPath: "/Applications/Gita.app"), bundleIdentifier: "x"))
        #expect(LoginItem.status != .enabled)
        #expect(throws: (any Error).self) { try LoginItem.setEnabled(true) }
        LoginItem.openSettings()
    }

    @Test(arguments: [
        (SMAppService.Status.enabled, LoginItem.Status.enabled), (.requiresApproval, .requiresApproval),
        (.notRegistered, .disabled), (.notFound, .disabled),
    ])
    func serviceStatuses(service: SMAppService.Status, expected: LoginItem.Status) {
        #expect(LoginItem.status(service) == expected)
    }

    @Test func theOfferIsForInteractiveReleaseLaunchesOnly() {
        #expect(
            LoginItem.offerAllowed(
                arguments: ["Gita"], isDevelopment: false, buildConfiguration: nil, answered: false))
        #expect(
            !LoginItem.offerAllowed(
                arguments: ["Gita"], isDevelopment: true, buildConfiguration: nil, answered: false))
        #expect(
            !LoginItem.offerAllowed(
                arguments: ["Gita"], isDevelopment: false, buildConfiguration: "debug", answered: false))
        #expect(
            !LoginItem.offerAllowed(
                arguments: ["Gita"], isDevelopment: false, buildConfiguration: nil, answered: true))
        #expect(
            !LoginItem.offerAllowed(
                arguments: ["Gita", "--background"], isDevelopment: false, buildConfiguration: nil, answered: false)
        )
        #expect(
            LoginItem.offerAllowed(
                arguments: ["Gita", "--repository=/tmp", "x"], isDevelopment: false, buildConfiguration: nil,
                answered: false))
        let settings = AppTestDefaults()
        var environment = AppEnvironment(
            isDevelopment: true, defaults: settings.defaults, arguments: ["Gita"], bundle: .main,
            startsServices: false, statusBar: NSStatusBar())
        #expect(!LoginItem.shouldOffer(environment: environment))
        LoginItem.answerOffer(defaults: settings.defaults)
        LoginItem.answerOffer(defaults: settings.defaults)
        #expect(Preference.loginItemOfferAnswered.bool(settings.defaults))
        environment.arguments = ["Gita", "--repository", "/tmp/x"]
        #expect(environment.commandLineRepository?.path == "/tmp/x")
        #expect(!LoginItem.wasLaunchedAtLogin)
    }

    @Test func languageNamesAndLocales() {
        #expect(AppLanguage.locale(global: "es_ES", language: "de").hasPrefix("de"))
        #expect(AppLanguage.name(of: "de").first?.isUppercase == true)
        #expect(AppLanguage.name(of: "th") == "ไทย")
        #expect(AppLanguage.locale(global: "en_US", language: "th").hasPrefix("th"))
        #expect(AppLanguage.targetLanguages.contains("th"))
        #expect(!AppLanguage.available.isEmpty)
        #expect(AppLanguage.available.contains(AppLanguage.system))
        _ = AppLanguage.needsRestart
        _ = AppLanguage.selected
        #expect(AppEnvironment.settings(development: false) === UserDefaults.standard)
        #expect(!AppEnvironment.compiledForDevelopment || AppEnvironment.current.isDevelopment)
    }
}
