import AppKit
import GitaCore

/// §8 Full-height PR Review workspace hosting `providerPage` (`listHost`) and `PullRequestReviewView` (`detailHost`)
/// with `< 1,100 pt` icon collapse, `< 900 pt` inline fallback, `← PRs` back button, and `⤢ Window` pop-out return.
extension RepositoryViewController {
    func wirePullRequestWorkspace() {
        providerPage.list.onSelectionChange = { [weak self] item in
            self?.pullRequestSelectionChanged(item)
        }
        prWorkspace.onLayoutChanged = { [weak self] _ in
            self?.syncPullRequestWorkspaceMode()
        }
    }

    func pullRequestSelectionChanged(_ item: ProviderItem?) {
        guard model.section == .pullRequests, let item, let root = model.snapshot?.root else {
            prWorkspace.clearReview()
            syncPullRequestWorkspaceMode()
            return
        }
        let width = effectivePullRequestWorkspaceWidth
        if ReviewPresentation.preferred(forWidth: width) == .inline {
            prWorkspace.clearReview()
            syncPullRequestWorkspaceMode()
            return
        }
        guard let controller = bindPullRequestReviewController(for: item, root: root) else {
            prWorkspace.clearReview()
            syncPullRequestWorkspaceMode()
            return
        }
        prWorkspace.showReview(controller.reviewView, isPoppedOut: controller.popOutWindow != nil)
        syncPullRequestWorkspaceMode()
    }

    func syncPullRequestWorkspaceMode() {
        let isPullRequests = model.section == .pullRequests
        let width = effectivePullRequestWorkspaceWidth
        let presentation = ReviewPresentation.preferred(forWidth: width)
        let selected = isPullRequests ? providerPage.list.selectedItem : nil
        let splitDetail = isPullRequests && presentation != .inline
        if !isPullRequests || !splitDetail || selected == nil {
            if prWorkspace.activeReview != nil { prWorkspace.clearReview() }
            providerPage.list.usesSplitDetail = splitDetail
            providerPage.setCompact(false)
            return
        }
        providerPage.list.usesSplitDetail = true
        if let item = selected, let root = model.snapshot?.root,
            let controller = bindPullRequestReviewController(for: item, root: root)
        {
            let poppedOut = controller.popOutWindow != nil
            if prWorkspace.activeReview !== controller.reviewView {
                prWorkspace.showReview(controller.reviewView, isPoppedOut: poppedOut)
            }
            providerPage.setCompact(prWorkspace.layoutState.collapsesListToIcons)
        }
    }

    private var effectivePullRequestWorkspaceWidth: CGFloat {
        let width = prWorkspace.bounds.width > 0 ? prWorkspace.bounds.width : pagePane.bounds.width
        return width > 0 ? width : 1_120
    }

    private func bindPullRequestReviewController(
        for item: ProviderItem, root: URL
    ) -> PullRequestReviewController? {
        guard let controller = PullRequestReviewController.review(item, root: root) else { return nil }
        controller.onBack = { [weak self] in
            self?.providerPage.list.clearSelection()
        }
        controller.onPopOut = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.prWorkspace.showReview(controller.reviewView, isPoppedOut: true)
            self.syncPullRequestWorkspaceMode()
        }
        controller.onReturnFromWindow = { [weak self, weak controller] _ in
            self?.handlePullRequestPopOutReturn(controller)
        }
        return controller
    }

    private func handlePullRequestPopOutReturn(_ controller: PullRequestReviewController?) {
        guard let controller, model.section == .pullRequests else { return }
        let width = effectivePullRequestWorkspaceWidth
        if ReviewPresentation.preferred(forWidth: width) == .inline {
            controller.reviewView.setPresentation(.inline)
            syncPullRequestWorkspaceMode()
            return
        }
        prWorkspace.showReview(controller.reviewView, isPoppedOut: false)
        syncPullRequestWorkspaceMode()
    }
}
