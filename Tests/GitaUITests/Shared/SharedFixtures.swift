import AppKit
import Foundation

@testable import GitaCore
@testable import GitaUI

/// Provider and agent model values for the shared-component tests.
enum SharedFixtures {
    static let repository = "octo/repo"
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func url(_ text: String) -> URL? { URL(string: text) }

    static func pullRequestItem(
        number: Int = 7, lifecycle: PullRequestLifecycle = .open, mergedBy: String? = nil, isDraft: Bool = false,
        url: URL? = URL(string: "https://github.com/octo/repo/pull/7")
    ) -> ProviderItem {
        let summary = PullRequestSummary(
            number: number, lifecycle: lifecycle, isDraft: isDraft, author: "octocat", mergedBy: mergedBy,
            createdAt: now.addingTimeInterval(-7_200), mergedAt: mergedBy == nil ? nil : now.addingTimeInterval(-60))
        return ProviderItem(
            id: "pr-\(number)", provider: .github, category: "Pull requests", title: "Add feature \(number)",
            state: .success, detail: lifecycle.rawValue, branch: "feature", url: url,
            date: now.addingTimeInterval(-3_600),
            kind: .pullRequest, target: .pullRequest(repository: repository, number: number), pullRequest: summary)
    }

    static func workflowItem(runID: Int64 = 42, state: SignalState = .failure) -> ProviderItem {
        ProviderItem(
            id: "run-\(runID)", provider: .github, category: "Workflow runs", title: "CI", state: state,
            detail: "failure", branch: "main", url: URL(string: "https://github.com/octo/repo/actions/runs/\(runID)"),
            kind: .workflowRun, target: .workflowRun(repository: repository, runID: runID, attempt: 1))
    }

    static func deploymentItem(
        reference: String = "dpl_one", url: URL? = URL(string: "https://one.vercel.app")
    )
        -> ProviderItem
    {
        ProviderItem(
            id: reference, provider: .vercel, category: "Deployments", title: "web", state: .success, detail: "READY",
            branch: "main", url: url, kind: .deployment,
            target: .deployment(reference: reference, projectName: "web", scope: "team"))
    }

    static func otherItem(id: String = "other") -> ProviderItem {
        ProviderItem(id: id, provider: .orca, category: "Other", title: "Something", state: .neutral, detail: "Idle")
    }

    static func check(
        _ name: String, _ state: SignalState, workflow: String? = "CI", url: URL? = nil
    )
        -> ProviderCheck
    {
        ProviderCheck(id: name, name: name, workflow: workflow, state: state, url: url)
    }

    /// An open pull request with a head and base branch, mergeable, by octocat; `change` adjusts it.
    static func pullRequestDetail(
        checks: [ProviderCheck] = [], total: Int? = nil, reviews: [ProviderReview] = [],
        requested: [String] = [], _ change: (inout PullRequestDetail) -> Void = { _ in }
    ) -> PullRequestDetail {
        var detail = PullRequestDetail(
            number: 7, title: "Add feature 7", author: "octocat", lifecycle: .open, baseBranch: "main",
            headBranch: "feature", reviewDecision: nil, mergeability: .mergeable,
            url: URL(string: "https://github.com/octo/repo/pull/7"),
            checks: ProviderPage(items: checks, total: total),
            reviews: ProviderPage(items: reviews),
            requestedReviewers: ProviderPage(items: requested.map { ProviderReviewer(id: $0, name: $0) }))
        change(&detail)
        return detail
    }

    static func workflowDetail(jobs: [WorkflowJob], total: Int? = nil, attempt: Int = 2) -> WorkflowRunDetail {
        WorkflowRunDetail(
            runID: 42, number: 12, attempt: attempt, title: "Build", workflow: "CI", event: "push", state: .failure,
            commit: "abcdef1234", branch: "main", url: URL(string: "https://github.com/octo/repo/actions/runs/42"),
            jobs: ProviderPage(items: jobs, total: total))
    }

    static func job(_ name: String, _ state: SignalState, steps: [WorkflowStep] = []) -> WorkflowJob {
        WorkflowJob(
            id: Int64(name.count), name: name, state: state, url: URL(string: "https://github.com/octo/repo/job/1"),
            startedAt: now, completedAt: now.addingTimeInterval(65), steps: steps, stepsTruncated: false)
    }

    static func deploymentDetail(
        state: SignalState = .failure, preview: URL? = URL(string: "https://one.vercel.app"),
        aliases: [URL] = [], dashboard: URL? = URL(string: "https://vercel.com/team/web/dpl_one"),
        duration: Double? = 42_000, project: DeploymentProject? = DeploymentProject(name: "web", framework: "nextjs")
    ) -> DeploymentDetail {
        DeploymentDetail(
            id: "dpl_one", projectName: "web-fallback", projectID: "prj", scope: "team", state: state,
            previewURL: preview, dashboardURL: dashboard, aliases: aliases, createdAt: now,
            durationMilliseconds: duration,
            reason: "Build failed", commit: "1a2b3c4d5e", branch: "main", project: project)
    }

    /// A Claude Code session; `subagentOf` makes it a subagent of that session id.
    static func session(
        _ id: String, state: AgentState = .working, since: TimeInterval = 0, checkout: URL? = nil,
        repository: URL? = nil, subagentOf parent: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, tool: .claudeCode, pid: nil, workingDirectory: checkout ?? URL(fileURLWithPath: "/tmp"),
            checkoutRoot: checkout, repositoryRoot: repository, state: state,
            stateSince: now.addingTimeInterval(since), evidence: .hook, isSubagent: parent != nil, parentID: parent)
    }

    /// A scratch defaults suite, removed by `remove`.
    static func scratchDefaults() -> (UserDefaults, String) {
        let name = "GitaUITests-" + UUID().uuidString
        return (UserDefaults(suiteName: name) ?? .standard, name)
    }
    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    /// Polls `condition` on the main actor, yielding between checks, for up to `seconds`.
    @MainActor static func waitUntil(seconds: Double = 120, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Every descendant of `view` of type `T`.
    @MainActor static func descendants<T: NSView>(_ view: NSView, of _: T.Type = T.self) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants($0, of: T.self) }
    }
    /// The visible strings of every label under `view`.
    @MainActor static func texts(_ view: NSView) -> [String] {
        descendants(view, of: NSTextField.self).map(\.stringValue)
    }
}

/// Records key and mouse events a view passes up the responder chain.
final class SharedResponderRecorder: NSResponder {
    var keys: [UInt16] = []
    var mouseDowns = 0
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    override func mouseDown(with _: NSEvent) { mouseDowns += 1 }
}

@MainActor
enum SharedEvents {
    static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
    /// A mouse event at `point` in `view`'s coordinates.
    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: 1)
    }
    static func window(containing view: NSView, size: NSSize = NSSize(width: 400, height: 200)) -> NSWindow {
        UITestSupport.bootstrap()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        view.frame = NSRect(origin: .zero, size: size)
        content.addSubview(view)
        return window
    }
}

@MainActor
final class SharedCounter {
    var value = 0
}
