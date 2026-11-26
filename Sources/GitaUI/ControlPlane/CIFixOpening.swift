import AppKit
import GitaCore

/// Something up a view's responder chain that launches the CI Fix sheet for a failed GitHub Actions workflow run.
@MainActor
protocol CIFixOpening: AnyObject {
    func openCIFix(run: WorkflowRunDetail, job: WorkflowJob?, step: WorkflowStep?, repository: String?)
}

extension NSResponder {
    var ciFixOpener: (any CIFixOpening)? {
        sequence(first: self, next: \.nextResponder).lazy.compactMap { $0 as? any CIFixOpening }.first
    }
}

extension PartsButton {
    static func fixWorkflow(
        _ run: WorkflowRunDetail, job: WorkflowJob? = nil, step: WorkflowStep? = nil,
        repository: String? = nil, from source: NSView
    ) -> PartsButton {
        let title = String(localized: "Fix with Agent…")
        let button = Self.quiet(title, symbol: "sparkles") { [weak source] in
            source?.ciFixOpener?.openCIFix(run: run, job: job, step: step, repository: repository)
        }
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }
}

extension RepositoryViewController: CIFixOpening {
    func openCIFix(run: WorkflowRunDetail, job: WorkflowJob?, step: WorkflowStep?, repository: String?) {
        guard let snapshot = model.snapshot else { return }
        let fallback = snapshot.github.map { remote in
            let prefix = "github:"
            return remote.sourceID.hasPrefix(prefix) ? String(remote.sourceID.dropFirst(prefix.count)) : remote.sourceID
        }
        guard let nameWithOwner = repository ?? fallback else { return }
        let sourceID = "github:" + nameWithOwner.lowercased()
        let account = GitHubAccountStore(defaults: model.defaults).use(for: sourceID)
        ControlPlaneFacade.shared.presentCIFixSheet(
            from: run, job: job, step: step, root: snapshot.root, repository: nameWithOwner, account: account,
            on: view.window)
    }
}
