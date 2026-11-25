import AppKit
import Combine
import Foundation
import Sparkle
import Testing
import os

@testable import GitaUI

@MainActor
final class FakeUpdaterDriver: UpdaterDriver {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true {
        didSet { automaticCheckWrites.append(automaticallyChecksForUpdates) }
    }
    var automaticallyDownloadsUpdates = false {
        didSet { automaticDownloadWrites.append(automaticallyDownloadsUpdates) }
    }
    var lastUpdateCheckDate: Date?
    var startCalls = 0
    var checkCalls = 0
    var automaticCheckWrites: [Bool] = []
    var automaticDownloadWrites: [Bool] = []
    private var changeHandler: (@MainActor (UpdaterDriverSnapshot) -> Void)?

    func startUpdater() { startCalls += 1 }
    func checkForUpdates() { checkCalls += 1 }

    func observeChanges(_ onChange: @escaping @MainActor (UpdaterDriverSnapshot) -> Void) -> AnyCancellable {
        changeHandler = onChange
        return AnyCancellable { [weak self] in self?.changeHandler = nil }
    }

    func emit(canCheck: Bool, autoCheck: Bool, autoDownload: Bool) {
        canCheckForUpdates = canCheck
        automaticallyChecksForUpdates = autoCheck
        automaticallyDownloadsUpdates = autoDownload
        automaticCheckWrites.removeAll()
        automaticDownloadWrites.removeAll()
        changeHandler?(
            UpdaterDriverSnapshot(
                canCheckForUpdates: canCheck,
                automaticallyChecksForUpdates: autoCheck,
                automaticallyDownloadsUpdates: autoDownload))
    }
}

@MainActor
@Suite("App updater")
struct AppUpdaterTests {
    private static func makeEnvironment(isDevelopment: Bool, startsServices: Bool) -> AppEnvironment {
        var env = AppEnvironment(
            isDevelopment: isDevelopment, defaults: .standard, arguments: [], bundle: .main,
            startsServices: startsServices, statusBar: .system)
        env.bundleURL = URL(fileURLWithPath: "/Applications/Gita.app")
        return env
    }

    @Test func doesNotStartInDevHeadlessOrUnsignedBuilds() {
        let driver = FakeUpdaterDriver()
        var unavailableCalls = 0
        var activateCalls = 0
        let updater = AppUpdater(
            driverFactory: { _ in driver },
            officialBuildCheck: { _ in true },
            activateApp: { activateCalls += 1 },
            presentUnavailable: { unavailableCalls += 1 })

        updater.start(environment: Self.makeEnvironment(isDevelopment: true, startsServices: true))
        #expect(!updater.isEnabled)
        updater.start(environment: Self.makeEnvironment(isDevelopment: false, startsServices: false))
        #expect(!updater.isEnabled)

        let unsignedUpdater = AppUpdater(
            driverFactory: { _ in driver },
            officialBuildCheck: { _ in false },
            activateApp: { activateCalls += 1 },
            presentUnavailable: { unavailableCalls += 1 })
        unsignedUpdater.start(environment: Self.makeEnvironment(isDevelopment: false, startsServices: true))
        #expect(!unsignedUpdater.isEnabled)
        #expect(driver.startCalls == 0)

        unsignedUpdater.checkForUpdates()
        #expect(activateCalls == 1)
        #expect(unavailableCalls == 1)
        #expect(driver.checkCalls == 0)
    }

    @Test func startsOnceOnOfficialBuildAndSyncsKVOWithoutFeedbackLoops() {
        let driver = FakeUpdaterDriver()
        let initialCheckDate = Date(timeIntervalSince1970: 1_700_000_000)
        driver.lastUpdateCheckDate = initialCheckDate
        var notifications = 0
        let updater = AppUpdater(
            driverFactory: { _ in driver },
            officialBuildCheck: { _ in true },
            activateApp: {},
            presentUnavailable: {})
        let token = updater.observe { notifications += 1 }
        defer { updater.removeObserver(token) }

        let env = Self.makeEnvironment(isDevelopment: false, startsServices: true)
        updater.start(environment: env)
        updater.start(environment: env)
        #expect(updater.isEnabled)
        #expect(driver.startCalls == 1)
        #expect(updater.canCheckForUpdates)
        #expect(updater.lastUpdateCheckDate == initialCheckDate)
        #expect(notifications >= 1)

        // UI -> driver writes once.
        driver.automaticCheckWrites.removeAll()
        driver.automaticDownloadWrites.removeAll()
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = true
        #expect(driver.automaticCheckWrites == [false])
        #expect(driver.automaticDownloadWrites == [true])

        // Driver KVO -> UI updates without writing back into the driver.
        driver.emit(canCheck: false, autoCheck: true, autoDownload: false)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.automaticallyChecksForUpdates)
        #expect(!updater.automaticallyDownloadsUpdates)
        #expect(driver.automaticCheckWrites.isEmpty)
        #expect(driver.automaticDownloadWrites.isEmpty)
    }

    @Test func manualCheckAndInstallTransitionsAndCycleResults() {
        let driver = FakeUpdaterDriver()
        let updater = AppUpdater(
            driverFactory: { _ in driver },
            officialBuildCheck: { _ in true },
            activateApp: {},
            presentUnavailable: {})
        updater.start(environment: Self.makeEnvironment(isDevelopment: false, startsServices: true))

        updater.checkForUpdates()
        #expect(updater.state == .checking)
        #expect(driver.checkCalls == 1)

        // Benign no-update error ends cycle as upToDate.
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        let checkedAt = Date(timeIntervalSince1970: 1_700_001_000)
        updater.recordUpdateCycleFinished(lastCheckDate: checkedAt, error: noUpdate)
        #expect(updater.state == .upToDate)
        #expect(updater.lastUpdateCheckDate == checkedAt)

        // Installation canceled error is also benign.
        updater.checkForUpdates()
        let canceled = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
        updater.recordUpdateCycleFinished(lastCheckDate: checkedAt, error: canceled)
        #expect(updater.state == .upToDate)

        // Real network error transitions checking -> failed.
        updater.checkForUpdates()
        let offline = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "Offline"])
        updater.recordUpdateCycleFinished(lastCheckDate: checkedAt, error: offline)
        #expect(updater.state == .failed("Offline"))

        // Found update stays `.available` across manual install and cycle completion.
        updater.recordFoundVersion("1.4.0")
        #expect(updater.availableVersion == "1.4.0")
        #expect(updater.pendingVersion == "1.4.0")
        #expect(updater.state == .available("1.4.0"))

        updater.installAvailableUpdate()
        #expect(updater.state == .available("1.4.0"))
        updater.recordUpdateCycleFinished(lastCheckDate: checkedAt, error: nil)
        #expect(updater.state == .available("1.4.0"))

        updater.clearPendingVersion()
        #expect(updater.pendingVersion == nil)
        updater.clearPendingVersion() // idempotent when already nil

        updater.recordNoUpdateFound()
        #expect(updater.availableVersion == nil)
        #expect(updater.pendingVersion == nil)
        #expect(updater.state == .upToDate)
    }

    @Test func sparkleDelegatesEnforceFeedOverrideAndGentleReminders() throws {
        let rawFeed = OSAllocatedUnfairLock<String?>(initialState: "http://127.0.0.1:4123/appcast.xml")
        let updater = AppUpdater(
            feedOverrideProvider: { rawFeed.withLock { $0 } },
            activateApp: {},
            presentUnavailable: {})
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: updater, userDriverDelegate: updater)
        let spu = controller.updater
        let item = SUAppcastItem.empty()

        #expect(updater.feedURLString(for: spu) == "http://127.0.0.1:4123/appcast.xml")
        rawFeed.withLock { $0 = "file:///etc/passwd" }
        #expect(updater.feedURLString(for: spu) == nil)
        rawFeed.withLock { $0 = nil }
        #expect(updater.feedURLString(for: spu) == nil)

        #expect(updater.supportsGentleScheduledUpdateReminders)
        #expect(updater.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true))
        #expect(!updater.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: false))

        updater.handleScheduledUpdatePresentation(handledBySparkle: true, version: "1.5.0")
        #expect(updater.pendingVersion == nil)
        updater.handleScheduledUpdatePresentation(handledBySparkle: false, version: "1.5.0")
        #expect(updater.pendingVersion == "1.5.0")
        #expect(updater.availableVersion == "1.5.0")

        updater.standardUserDriverDidReceiveUserAttention(forUpdate: item)
        #expect(updater.pendingVersion == nil)

        updater.updater(spu, didFindValidUpdate: item)
        #expect(updater.pendingVersion == item.displayVersionString)
        updater.standardUserDriverWillFinishUpdateSession()
        #expect(updater.pendingVersion == nil)

        updater.updaterDidNotFindUpdate(spu)
        #expect(updater.state == .upToDate)

        let error = NSError(domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Network failed"])
        updater.updater(spu, failedToDownloadUpdate: item, error: error)
        updater.updater(spu, didAbortWithError: error)
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        updater.updater(spu, didAbortWithError: noUpdate)
        updater.updater(spu, didFinishUpdateCycleFor: .updates, error: nil)
    }

    @Test func sparkleUpdaterDriverExposesKVOPropertiesWithoutStarting() {
        let updater = AppUpdater(activateApp: {}, presentUnavailable: {})
        let driver = SparkleUpdaterDriver(updaterDelegate: updater, userDriverDelegate: updater)
        var snapshots: [UpdaterDriverSnapshot] = []
        let cancellable = driver.observeChanges { snapshots.append($0) }
        defer { cancellable.cancel() }

        let initialAuto = driver.automaticallyChecksForUpdates
        driver.automaticallyChecksForUpdates = !initialAuto
        driver.automaticallyChecksForUpdates = initialAuto
        let initialDownload = driver.automaticallyDownloadsUpdates
        driver.automaticallyDownloadsUpdates = !initialDownload
        driver.automaticallyDownloadsUpdates = initialDownload

        _ = driver.canCheckForUpdates
        _ = driver.lastUpdateCheckDate
        #expect(!snapshots.isEmpty)
    }
}
