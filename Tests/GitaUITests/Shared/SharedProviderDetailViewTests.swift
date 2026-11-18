import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Records detail loads and answers each with the next queued report.
@MainActor
final class SharedDetailLoaderRecorder {
    var calls: [(ProviderItem, Bool)] = []
    var replies: [ProviderDetailReport?] = []
    var loader: ProviderDetailLoader {
        { [self] item, force in
            calls.append((item, force))
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
}

@MainActor
@Suite struct SharedProviderDetailViewTests {
    private func show(
        _ item: ProviderItem, replies: [ProviderDetailReport?], header: Bool = true
    ) async throws -> (ProviderDetailView, SharedDetailLoaderRecorder, NSWindow) {
        let recorder = SharedDetailLoaderRecorder()
        recorder.replies = replies
        let view = ProviderDetailView(item: item, loader: recorder.loader)
        view.showsHeader = header
        let window = SharedEvents.window(containing: view, size: NSSize(width: 600, height: 400))
        let unavailable = String(localized: "Details unavailable")
        #expect(
            await SharedFixtures.waitUntil { view.report != nil || SharedFixtures.texts(view).contains(unavailable) })
        view.layoutSubtreeIfNeeded()
        UITestSupport.render(view)
        return (view, recorder, window)
    }

    @Test func pullRequestCardShowsEveryRow() async throws {
        let item = SharedFixtures.pullRequestItem(lifecycle: .merged, mergedBy: "hubot")
        let checks = [
            SharedFixtures.check("unit", .failure, url: URL(string: "https://github.com/octo/repo/runs/1")),
            SharedFixtures.check("lint", .success),
        ]
        let detail = SharedFixtures.pullRequestDetail(
            checks: checks, reviews: [ProviderReview(id: "1", author: "ada", status: .approved)])
        let target = try #require(item.target)
        let report = ProviderDetailReport(target: target, content: .pullRequest(detail), status: .connected)
        let (view, recorder, window) = try await show(item, replies: [report])
        defer { window.close() }
        #expect(recorder.calls.map(\.1) == [false])
        let texts = SharedFixtures.texts(view)
        for title in ["Opened by", "Merged by", "Branch", "Reviews", "Checks", "Merge"] {
            #expect(texts.contains(title), "\(title)")
        }
        #expect(texts.contains("#7 Add feature 7"))
        #expect(texts.contains("feature → main"))
        #expect(texts.contains("CI · unit"))
        let links = SharedFixtures.descendants(view, of: PartsButton.self)
        #expect(links.contains { $0.accessibilityLabel() == String(localized: "Logs ↗") })
        #expect(links.contains { $0.accessibilityLabel() == String(localized: "Open on GitHub") })
    }

    @Test func workflowCardListsJobsAndFailedSteps() async throws {
        let item = SharedFixtures.workflowItem()
        let jobs = [
            SharedFixtures.job(
                "build", .failure,
                steps: [
                    WorkflowStep(number: 1, name: "Checkout", state: .success),
                    WorkflowStep(number: 2, name: "Compile", state: .failure),
                ]),
            SharedFixtures.job("test", .success),
        ]
        let target = try #require(item.target)
        let report = ProviderDetailReport(
            target: target, content: .workflowRun(SharedFixtures.workflowDetail(jobs: jobs)), status: .connected)
        let (view, _, window) = try await show(item, replies: [report])
        defer { window.close() }
        let texts = SharedFixtures.texts(view)
        #expect(texts.contains("CI · push"))
        #expect(texts.contains("    2. Compile"))
        #expect(!texts.contains("    1. Checkout"))
        #expect(texts.contains("2"), "attempt")
        #expect(texts.contains(DeckFormat.duration(65)))
    }

    @Test func workflowWithoutJobsSaysSoWithoutAHeader() async throws {
        let item = SharedFixtures.workflowItem()
        let target = try #require(item.target)
        let report = ProviderDetailReport(
            target: target, content: .workflowRun(SharedFixtures.workflowDetail(jobs: [], total: 0, attempt: 1)),
            status: .connected)
        let (view, _, window) = try await show(item, replies: [report], header: false)
        defer { window.close() }
        let texts = SharedFixtures.texts(view)
        #expect(texts.contains(String(localized: "No jobs")))
        #expect(!texts.contains("#12 Build"))
    }

    @Test func deploymentCardShowsAddressesBuildAndInspect() async throws {
        let item = SharedFixtures.deploymentItem()
        let target = try #require(item.target)
        let detail = SharedFixtures.deploymentDetail(aliases: [try #require(URL(string: "https://web.example.com"))])
        let report = ProviderDetailReport(target: target, content: .deployment(detail), status: .connected)
        let (view, _, window) = try await show(item, replies: [report])
        defer { window.close() }
        let texts = SharedFixtures.texts(view)
        #expect(texts.contains("one.vercel.app"))
        #expect(texts.contains("web.example.com"))
        #expect(texts.contains("main · 1a2b3c4"))
        #expect(texts.contains("Build failed"))
        #expect(texts.contains("web · nextjs · team"))
        let labels = SharedFixtures.descendants(view, of: PartsButton.self).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains(String(localized: "Inspect ↗")))
        #expect(labels.filter { $0 == String(localized: "Copy") }.count == 2)
    }

    @Test func aMissingReportOffersTryAgainWhichForcesARefresh() async throws {
        let item = SharedFixtures.pullRequestItem()
        let target = try #require(item.target)
        let detail = SharedFixtures.pullRequestDetail()
        let (view, recorder, window) = try await show(
            item,
            replies: [nil, ProviderDetailReport(target: target, content: .pullRequest(detail), status: .connected)])
        defer { window.close() }
        #expect(SharedFixtures.texts(view).contains(String(localized: "Details unavailable")))
        let retry = try #require(
            SharedFixtures.descendants(view, of: PartsButton.self).first {
                $0.accessibilityLabel() == String(localized: "Try Again")
            })
        #expect(retry.accessibilityPerformPress())
        #expect(await SharedFixtures.waitUntil { view.report != nil })
        #expect(recorder.calls.map(\.1) == [false, true])
        #expect(!SharedFixtures.descendants(view, of: PartsButton.self).contains { $0 === retry })
    }

    @Test func aReportForAnotherTargetOrWithoutContentIsAFailure() async throws {
        let item = SharedFixtures.pullRequestItem()
        let other = ProviderTarget.pullRequest(repository: "someone/else", number: 1)
        let (view, recorder, window) = try await show(
            item, replies: [ProviderDetailReport(target: other, status: .connected)])
        defer { window.close() }
        #expect(view.report == nil)
        #expect(SharedFixtures.texts(view).contains(String(localized: "Details unavailable")))
        let target = try #require(item.target)
        recorder.replies = [ProviderDetailReport(target: target, status: .unavailable, diagnostic: "offline")]
        view.load(force: true)
        #expect(await SharedFixtures.waitUntil { view.report != nil })
        #expect(SharedFixtures.texts(view).contains(ProviderText.status("Unavailable") + " · offline"))
    }

    @Test func leavingTheWindowCancelsALoadInFlight() async throws {
        let item = SharedFixtures.pullRequestItem()
        let resumed = SharedFlag()
        let view = ProviderDetailView(item: item) { _, _ in
            // Far longer than the wait below: only cancellation wakes it in time.
            try? await Task.sleep(for: .seconds(600))
            resumed.value = true
            return nil
        }
        let window = SharedEvents.window(containing: view)
        defer { window.close() }
        #expect(SharedFixtures.texts(view).contains(String(localized: "Loading…")))
        view.removeFromSuperview()
        #expect(await SharedFixtures.waitUntil { resumed.value }, "the cancelled load wakes up early")
        try await Task.sleep(for: .milliseconds(20))
        #expect(view.report == nil)
        #expect(!SharedFixtures.texts(view).contains(String(localized: "Details unavailable")))
    }

    /// A loader that waits while `held` is set and then answers from `recorder`; a stopped read answers nothing.
    private func heldLoader(_ held: SharedFlag, _ recorder: SharedDetailLoaderRecorder) -> ProviderDetailLoader {
        { item, force in
            recorder.calls.append((item, force))
            while held.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            if Task.isCancelled || recorder.replies.isEmpty { return nil }
            return recorder.replies.removeFirst()
        }
    }

    /// A read that stops (the row collapsed) takes its Loading… or Refreshing… with it and gives way to what was
    /// shown before; shown again with nothing on screen, the row reads again.
    @Test func aStoppedReadLeavesNoProgressBehindAndReadsAgainWhenShown() async throws {
        let item = SharedFixtures.pullRequestItem()
        let target = try #require(item.target)
        let report = ProviderDetailReport(
            target: target, content: .pullRequest(SharedFixtures.pullRequestDetail()), status: .connected)
        let held = SharedFlag()
        held.value = true
        let recorder = SharedDetailLoaderRecorder()
        let view = ProviderDetailView(item: item, loader: heldLoader(held, recorder))
        let window = SharedEvents.window(containing: view)
        defer { window.close() }
        let host = try #require(view.superview)
        let loading = String(localized: "Loading…")
        #expect(SharedFixtures.texts(view).contains(loading))
        view.removeFromSuperview()
        #expect(!SharedFixtures.texts(view).contains(loading))
        #expect(view.phase.footer == .init() && !view.phase.isReading)
        held.value = false
        recorder.replies = [report]
        host.addSubview(view)
        #expect(await SharedFixtures.waitUntil { view.report != nil })
        #expect(recorder.calls.map(\.1) == [false, false])

        held.value = true
        view.load(force: true)
        let refreshing = String(localized: "Refreshing…")
        #expect(SharedFixtures.texts(view).contains(refreshing) && view.report != nil)
        view.removeFromSuperview()
        #expect(!SharedFixtures.texts(view).contains(refreshing))
        #expect(view.phase.footer == .init() && view.report != nil, "the report shown before stays")
        held.value = false
    }

    /// Try Again goes while its own read runs, so it cannot start a second one, and comes back if that read fails.
    @Test func tryAgainHidesWhileItsOwnReadRuns() async throws {
        let item = SharedFixtures.pullRequestItem()
        let held = SharedFlag()
        let recorder = SharedDetailLoaderRecorder()
        recorder.replies = [nil]
        let view = ProviderDetailView(item: item, loader: heldLoader(held, recorder))
        let window = SharedEvents.window(containing: view)
        defer { window.close() }
        let retries = {
            SharedFixtures.descendants(view, of: PartsButton.self).filter {
                $0.accessibilityLabel() == String(localized: "Try Again")
            }
        }
        #expect(await SharedFixtures.waitUntil { retries().count == 1 })
        held.value = true
        #expect(retries().first?.accessibilityPerformPress() == true)
        #expect(retries().isEmpty)
        #expect(view.phase.footer.spins && !view.phase.footer.offersRetry)
        held.value = false
        #expect(await SharedFixtures.waitUntil { retries().count == 1 })
        #expect(recorder.calls.map(\.1) == [false, true])
        #expect(view.phase.footer.isFailure)
    }

    @Test func thePhaseSaysWhatTheFooterShows() throws {
        let target = try #require(SharedFixtures.pullRequestItem().target)
        let report = ProviderDetailReport(target: target, status: .connected)
        typealias Phase = ProviderDetailView.Phase
        #expect(Phase.idle.footer == .init() && Phase.idle.report == nil)
        #expect(Phase.loading.footer == .init(text: String(localized: "Loading…"), spins: true))
        #expect(Phase.loading.stopped.footer == .init() && Phase.loading.isReading)
        let refreshing = Phase.refreshing(previous: .loaded(report))
        #expect(refreshing.footer.text == String(localized: "Refreshing…") && refreshing.report != nil)
        #expect(refreshing.stopped.report != nil && !refreshing.stopped.isReading)
        let failed = Phase.failed(nil, message: "Nope")
        #expect(failed.footer == .init(text: "Nope", isFailure: true, offersRetry: true))
        #expect(failed.stopped.footer == failed.footer)
        #expect(Phase.refreshing(previous: failed).stopped.footer == failed.footer)
        #expect(Phase.failed(report, message: "Nope").report != nil)
    }
}

@MainActor
final class SharedFlag {
    var value = false
}
