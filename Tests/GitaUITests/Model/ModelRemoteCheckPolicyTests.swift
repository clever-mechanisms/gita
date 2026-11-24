import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

extension RemoteNetworkStatus {
    static let online = Self(isSatisfied: true, isConstrained: false, isExpensive: false, isLowPowerMode: false)
    static let offline = Self(isSatisfied: false, isConstrained: false, isExpensive: false, isLowPowerMode: false)
}

extension RemoteCheckState {
    var isFetching: Bool {
        if case .fetching = phase { true } else { false }
    }
}

@Suite("Remote update preferences, state summaries and scheduling policy")
@MainActor
struct ModelRemoteCheckPolicyTests {
    @Test func preferencesDefaultToCheckOnAndAutoFetchOff() {
        let settings = AppTestDefaults()
        let defaults = settings.defaults
        let loaded = RemoteUpdateSettings.load(from: defaults)
        #expect(loaded.checkEnabled)
        #expect(!loaded.autoFetchEnabled)
        #expect(loaded.cadence == .fifteen)
        #expect(loaded.scope == .allOpenTabs)
        #expect(loaded.pauseOnLowDataOrPower)
        #expect(loaded.checkOnWindowFocus)

        Preference.registerDefaults(in: defaults)
        #expect(Preference.remoteCheck.bool(defaults))
        #expect(!Preference.remoteAutoFetch.bool(defaults))
        #expect(Preference.remoteCheckCadence.int(defaults) == 15)
        #expect(Preference.remoteCheckScope.string(defaults) == RemoteCheckScope.allOpenTabs.rawValue)

        #expect(RemoteCheckCadence(stored: 99) == .fifteen)
        #expect(RemoteCheckCadence.five.interval == 300)
        #expect(RemoteCheckCadence.thirty.interval == 1_800)
        #expect(RemoteCheckScope(stored: "bogus") == .allOpenTabs)
        #expect(Preference.remoteUpdateKeys.count == 6)
    }

    @Test func stateAccessorsAndStatusSummariesCoverAllCases() {
        let now = Date(timeIntervalSince1970: 10_000)
        let tip = RemoteTip(localOID: "a", remoteOID: "b")
        let singleDelta = RemoteDelta(
            moved: [RemoteBranchKey(remote: "origin", branch: "main"): tip],
            currentUpstreamMoved: false, checkedAt: now.addingTimeInterval(-120))
        let upstreamDelta = RemoteDelta(
            moved: [RemoteBranchKey(remote: "origin", branch: "main"): tip],
            currentUpstreamMoved: true, checkedAt: now.addingTimeInterval(-10))
        let multiDelta = RemoteDelta(
            moved: [
                RemoteBranchKey(remote: "origin", branch: "main"): tip,
                RemoteBranchKey(remote: "origin", branch: "dev"): tip,
            ],
            currentUpstreamMoved: false, checkedAt: now.addingTimeInterval(-10))

        #expect(RemoteCheckState().last == nil)
        #expect(!RemoteCheckState().isBusy)
        #expect(RemoteCheckState().statusSummary(now: now) == String(localized: "Remote checks off"))

        let task = Task<Void, Never> {}
        defer { task.cancel() }
        let checking = RemoteCheckState(phase: .checking(UUID(), task), last: singleDelta)
        let fetching = RemoteCheckState(phase: .fetching(UUID(), task), last: singleDelta)
        #expect(checking.isBusy && !checking.isFetching && checking.last == singleDelta)
        #expect(fetching.isBusy && fetching.isFetching && fetching.task != nil)
        #expect(checking.statusSummary(now: now) == String(localized: "Checking remotes…"))
        #expect(fetching.statusSummary(now: now) == String(localized: "Fetching updates…"))
        #expect(RemoteCheckState(phase: .offline).statusSummary(now: now) == String(localized: "Offline"))

        #expect(
            RemoteCheckState(phase: .waiting(next: now), last: nil).statusSummary(now: now)
                == String(localized: "Waiting to check remotes"))
        #expect(
            RemoteCheckState(phase: .waiting(next: now), last: upstreamDelta).statusSummary(now: now).contains(
                "Upstream moved"))
        #expect(
            RemoteCheckState(phase: .waiting(next: now), last: singleDelta).statusSummary(now: now).contains(
                "1 branch moved"))
        #expect(
            RemoteCheckState(phase: .waiting(next: now), last: multiDelta).statusSummary(now: now).contains(
                "2 branches moved"))

        let authBackoff = RemoteCheckState(
            phase: .backingOff(
                until: .distantFuture, reason: .authenticationRequired), last: nil)
        let httpBackoff = RemoteCheckState(
            phase: .backingOff(
                until: .distantFuture, reason: .unsupportedURL), last: nil)
        let netBackoff = RemoteCheckState(
            phase: .backingOff(
                until: now.addingTimeInterval(300), reason: .unreachable), last: nil)
        #expect(authBackoff.statusSummary(now: now) == String(localized: "Sign-in needed · checks paused"))
        #expect(httpBackoff.statusSummary(now: now) == String(localized: "Unsupported remote URL"))
        #expect(netBackoff.statusSummary(now: now).contains("Offline, retrying in"))
    }

    @Test func backoffDelayScalesExponentiallyWithBoundedJitter() {
        #expect(RemoteCheckPolicy.nextDelay(failures: 1, jitterFraction: 0) == 5 * 60)
        #expect(RemoteCheckPolicy.nextDelay(failures: 2, jitterFraction: 0) == 10 * 60)
        #expect(RemoteCheckPolicy.nextDelay(failures: 3, jitterFraction: 0) == 20 * 60)
        #expect(RemoteCheckPolicy.nextDelay(failures: 4, jitterFraction: 0) == 40 * 60)
        #expect(RemoteCheckPolicy.nextDelay(failures: 5, jitterFraction: 0) == 60 * 60)
        #expect(RemoteCheckPolicy.nextDelay(failures: 9, jitterFraction: 0) == 60 * 60)
        #expect(RemoteCheckPolicy.nextDelay(failures: 1, jitterFraction: 2) == 330)
        #expect(RemoteCheckPolicy.nextDelay(failures: 1, jitterFraction: -2) == 270)
    }

    @Test func autoFetchAndFocusAndSchedulePoliciesRespectConstraints() {
        let now = Date(timeIntervalSince1970: 10_000)
        let delta = RemoteDelta(
            moved: [RemoteBranchKey(remote: "origin", branch: "main"): RemoteTip(localOID: "a", remoteOID: "b")],
            checkedAt: now)
        var settings = RemoteUpdateSettings(
            checkEnabled: true, autoFetchEnabled: true, cadence: .thirty, scope: .frontTabOnly,
            pauseOnLowDataOrPower: true, checkOnWindowFocus: true)

        #expect(RemoteCheckPolicy.shouldFetch(delta: delta, settings: settings, network: .online))
        #expect(
            !RemoteCheckPolicy.shouldFetch(delta: RemoteDelta(checkedAt: now), settings: settings, network: .online))
        #expect(!RemoteCheckPolicy.shouldFetch(delta: delta, settings: settings, network: .offline))
        let lowPower = RemoteNetworkStatus(
            isSatisfied: true, isConstrained: false, isExpensive: false, isLowPowerMode: true)
        #expect(!RemoteCheckPolicy.shouldFetch(delta: delta, settings: settings, network: lowPower))
        settings.pauseOnLowDataOrPower = false
        #expect(RemoteCheckPolicy.shouldFetch(delta: delta, settings: settings, network: lowPower))

        // Focus uses min(cadence, 5m) for check and full cadence for fetch.
        #expect(
            RemoteCheckPolicy.onBecomingFront(
                settings: settings, network: .online, lastCheck: now.addingTimeInterval(-299),
                lastFetch: nil, now: now) == .none)
        #expect(
            RemoteCheckPolicy.onBecomingFront(
                settings: settings, network: .online, lastCheck: now.addingTimeInterval(-301),
                lastFetch: now.addingTimeInterval(-600), now: now) == .check(allowAutoFetch: false))
        #expect(
            RemoteCheckPolicy.onBecomingFront(
                settings: settings, network: .online, lastCheck: now.addingTimeInterval(-301),
                lastFetch: now.addingTimeInterval(-1_801), now: now) == .check(allowAutoFetch: true))

        // Scheduled check honors scope and auth/url pause.
        #expect(
            !RemoteCheckPolicy.isScheduledCheckDue(
                state: .off, settings: settings, network: .online, isFrontTab: false, now: now))
        #expect(
            RemoteCheckPolicy.isScheduledCheckDue(
                state: .waiting(next: now.addingTimeInterval(-1)),
                settings: settings, network: .online, isFrontTab: true, now: now))
        #expect(
            !RemoteCheckPolicy.isScheduledCheckDue(
                state: .backingOff(
                    until: now.addingTimeInterval(-1), reason: .authenticationRequired),
                settings: settings, network: .online, isFrontTab: true, now: now))
        #expect(
            RemoteCheckPolicy.isScheduledCheckDue(
                state: .backingOff(until: now.addingTimeInterval(-1), reason: .unreachable),
                settings: settings, network: .online, isFrontTab: true, now: now))
    }
}
