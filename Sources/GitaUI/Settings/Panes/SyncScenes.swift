import AppKit
import GitaCore

/// What `SyncIllustrationView` plays: for each Pull mode and Merge default, the two situations it meets (only the
/// incoming side has new commits, or both sides do), each as the history before the operation and after it.
@MainActor
enum SyncScenes {
    typealias Commit = SceneGraph.Commit

    enum Situation: CaseIterable {
        /// Only the incoming side has new commits: the branch could just move up to it.
        case behind
        /// Both sides have new commits.
        case diverged

        var next: Self { self == .behind ? .diverged : .behind }
    }

    /// One picture: a choice in a situation, before or after the operation.
    struct Still: Equatable {
        var choice: SyncIllustrationView.Choice
        var situation: Situation
        var after: Bool
    }

    /// The rows every picture fills: the older commits run on out of the bottom.
    static let rows = 7
    private static let headerHeight: CGFloat = 18
    private static let gap: CGFloat = 8

    /// `still` on the scene's panel, `amount` (0…1) of the way from `previous`. Within one situation the operation
    /// slides commits and labels into place (`moves`); otherwise, and with reduced motion, the pictures cross-fade.
    static func card(_ still: Still, from previous: Still?, amount: CGFloat, moves: Bool, in bounds: NSRect) {
        SetupScenes.panel(bounds)
        let body = bounds.insetBy(dx: 14, dy: 12)
        let graph = NSRect(
            x: body.minX, y: body.minY + headerHeight + gap, width: body.width,
            height: SceneGraph.rowHeight * CGFloat(rows))
        let new = SceneGraph.layout(history(still), in: graph)
        guard let previous, amount < 1 else {
            SceneGraph.draw(new)
            words(still, in: body, below: graph.maxY + gap, alpha: 1)
            return
        }
        let old = SceneGraph.layout(history(previous), in: graph)
        if moves && previous.choice == still.choice && previous.situation == still.situation {
            SceneGraph.draw(from: old, to: new, amount: amount)
        } else {
            SceneGraph.draw(old) { _ in 1 - amount }
            SceneGraph.draw(new) { _ in amount }
        }
        if Words(previous) == Words(still) {
            words(still, in: body, below: graph.maxY + gap, alpha: 1)
        } else {
            words(previous, in: body, below: graph.maxY + gap, alpha: 1 - amount)
            words(still, in: body, below: graph.maxY + gap, alpha: amount)
        }
    }

    /// The text of a still: the situation, a Before/After tag and what the choice does there.
    private struct Words: Equatable {
        var title: String
        var tag: String
        var tagColor: NSColor
        var caption: String

        @MainActor
        init(_ still: Still) {
            title = SyncScenes.title(still.choice, still.situation)
            caption = SyncScenes.caption(still.choice, still.situation)
            switch (still.after, SyncScenes.stops(still.choice, still.situation)) {
            case (false, _): (tag, tagColor) = (String(localized: "Before"), Theme.secondaryText)
            case (true, true): (tag, tagColor) = (String(localized: "Stops"), Theme.needsInputText)
            case (true, false): (tag, tagColor) = (String(localized: "After"), Theme.accentText)
            }
        }
    }

    private static func words(_ still: Still, in body: NSRect, below top: CGFloat, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        let words = Words(still)
        let tagWidth = SetupScenes.pillWidth(words.tag, image: false)
        SetupScenes.pill(
            words.tag, at: NSPoint(x: body.maxX - tagWidth, y: body.minY), color: words.tagColor, alpha: alpha)
        SetupScenes.text(
            words.title, at: NSPoint(x: body.minX, y: body.minY + 2), font: Theme.captionEmphasis,
            color: Theme.secondaryText, alpha: alpha, width: max(0, body.width - tagWidth - 8))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        NSAttributedString(
            string: words.caption,
            attributes: [
                .font: Theme.caption, .foregroundColor: Theme.secondaryText.withAlphaComponent(alpha),
                .paragraphStyle: paragraph,
            ]
        ).draw(
            with: NSRect(x: body.minX, y: top, width: body.width, height: body.maxY - top),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: The histories

    /// Pull: you committed “Fix typo”, the remote got “Add search”. Merge: `search` has two commits, and `main` has
    /// “Fix typo” when both moved. Every picture ends on the same older commits, cut at `rows`; a missing parent is
    /// older history.
    static func history(_ still: Still) -> [Commit] {
        let recent =
            switch still.choice {
            case .pull(let mode): pull(mode, still.situation, after: still.after)
            case .merge(let mode): merge(mode, still.situation, after: still.after)
            }
        return Array((recent + older).prefix(rows))
    }

    /// The history under “Release 0.9”, the same in every picture; as much of it shows as the rows leave room for.
    private static var older: [Commit] {
        [
            Commit(id: "readme", subject: String(localized: "Update README"), parents: ["login"]),
            Commit(id: "login", subject: String(localized: "Add login"), parents: ["previous"]),
            Commit(id: "previous", subject: String(localized: "Release 0.8"), parents: ["ci"]),
            Commit(id: "ci", subject: String(localized: "Set up CI"), parents: ["initial"]),
            Commit(id: "initial", subject: String(localized: "Initial commit")),
        ]
    }

    /// Whether the choice refuses in the situation, so nothing changes.
    static func stops(_ choice: SyncIllustrationView.Choice, _ situation: Situation) -> Bool {
        situation == .diverged && (choice == .pull(.fastForwardOnly) || choice == .merge(.fastForwardOnly))
    }

    private static func release(_ labels: [String] = [], head: Bool = false) -> Commit {
        Commit(
            id: "release", subject: String(localized: "Release 0.9"), parents: ["readme"], labels: labels, isHead: head)
    }
    private static func typo(onMain: Bool, parent: String = "release") -> Commit {
        Commit(
            id: "typo", subject: String(localized: "Fix typo"), parents: [parent], labels: onMain ? ["main"] : [],
            isHead: onMain)
    }
    private static func merged(_ subject: String, parents: [String]) -> Commit {
        Commit(id: "merge", subject: subject, parents: parents, labels: ["main"], isHead: true)
    }

    private static func pull(_ mode: GitPullMode, _ situation: Situation, after: Bool) -> [Commit] {
        let remote = "origin/main"
        let search = Commit(
            id: "search", subject: String(localized: "Add search"), parents: ["release"], labels: [remote])
        switch situation {
        case .behind:
            guard after else { return [search, release(["main"], head: true)] }
            // Every mode only moves main up: there is nothing to join or replay.
            var moved = search
            moved.labels = ["main", remote]
            moved.isHead = true
            return [moved, release()]
        case .diverged:
            guard after else { return [typo(onMain: true), search, release()] }
            switch mode {
            case .fastForwardOnly:
                return [typo(onMain: true), search, release()]
            case .merge:
                return [
                    merged(String(localized: "Merge origin/main"), parents: ["typo", "search"]),
                    typo(onMain: false), search, release(),
                ]
            case .rebase:
                return [typo(onMain: true, parent: "search"), search, release()]
            }
        }
    }

    private static func merge(_ mode: GitMergeMode, _ situation: Situation, after: Bool) -> [Commit] {
        let tests = Commit(id: "tests", subject: String(localized: "Tests"), parents: ["field"], labels: ["search"])
        let field = Commit(id: "field", subject: String(localized: "Search field"), parents: ["release"])
        let mergeSubject = String(localized: "Merge search")
        switch situation {
        case .behind:
            guard after else { return [tests, field, release(["main"], head: true)] }
            guard mode != .noFastForward else {
                return [merged(mergeSubject, parents: ["release", "tests"]), tests, field, release()]
            }
            var moved = tests
            moved.labels = ["main", "search"]
            moved.isHead = true
            return [moved, field, release()]
        case .diverged:
            guard after, mode != .fastForwardOnly else { return [typo(onMain: true), tests, field, release()] }
            return [merged(mergeSubject, parents: ["typo", "tests"]), typo(onMain: false), tests, field, release()]
        }
    }

    // MARK: The words

    static func title(_ choice: SyncIllustrationView.Choice, _ situation: Situation) -> String {
        switch (choice, situation) {
        case (.pull, .behind): String(localized: "Only the remote has new commits")
        case (.pull, .diverged): String(localized: "Both sides have new commits")
        case (.merge, .behind): String(localized: "Only search has new commits")
        case (.merge, .diverged): String(localized: "Both branches have new commits")
        }
    }

    static func caption(_ choice: SyncIllustrationView.Choice, _ situation: Situation) -> String {
        switch choice {
        case .pull(let mode): pullCaption(mode, situation)
        case .merge(let mode): mergeCaption(mode, situation)
        }
    }

    private static func pullCaption(_ mode: GitPullMode, _ situation: Situation) -> String {
        switch (mode, situation) {
        case (.fastForwardOnly, .behind):
            String(localized: "main moves up to origin/main. No commit is made.")
        case (.fastForwardOnly, .diverged):
            String(localized: "Pull stops and nothing changes; merge or rebase to bring the commits in.")
        case (.merge, .behind):
            String(localized: "Nothing to join, so main just moves up to origin/main.")
        case (.merge, .diverged):
            String(localized: "A merge commit joins your commit and the remote's. Nothing is rewritten.")
        case (.rebase, .behind):
            String(localized: "Nothing to replay, so main just moves up to origin/main.")
        case (.rebase, .diverged):
            String(localized: "Your commit is replayed on top of the remote's: one straight line, new commit IDs.")
        }
    }

    private static func mergeCaption(_ mode: GitMergeMode, _ situation: Situation) -> String {
        switch (mode, situation) {
        case (.automatic, .behind):
            String(localized: "main moves up to search. No merge commit is needed.")
        case (.automatic, .diverged):
            String(localized: "main cannot just move up, so a merge commit joins the two.")
        case (.noFastForward, .behind):
            String(localized: "A merge commit even though main could move up, so the branch stays visible.")
        case (.noFastForward, .diverged):
            String(localized: "A merge commit joins the two branches.")
        case (.fastForwardOnly, .behind):
            String(localized: "main moves up to search. No commit is made.")
        case (.fastForwardOnly, .diverged):
            String(localized: "Merge stops and nothing changes, since main has commits search lacks.")
        }
    }
}
