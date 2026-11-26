import AppKit
import GitaCore

extension RepositoryViewController {
    static var sharedReviewedHunksProvider: (() -> ReviewedHunksRegistry?)?
    private static let fallbackReviews = ReviewedHunksRegistry()

    func resetReviewedHunks() {
        hunkReview?.presenter.cancel()
        hunkReview = nil
        clearHunkReviewControls()
    }

    private func clearHunkReviewControls() {
        hunkReview?.bar.onChange = nil
        codePane.setReviewedHunksBar(nil)
        codePane.diffView.reviewAction = nil
        codePane.diffView.setHiddenReviewHunks([])
    }

    func syncReviewedHunks() {
        let diff = codePane.diffView
        guard !diff.isBlob, let document = diff.document, !document.hunks.isEmpty,
            let path = diff.shownPath, let root = model.snapshot?.root
        else {
            clearHunkReviewControls()
            return
        }
        if hunkReview?.root != root {
            hunkReview?.presenter.cancel()
            let registry = Self.sharedReviewedHunksProvider?() ?? Self.fallbackReviews
            let presenter = registry.makeReviewedHunksPresenter(for: root)
            hunkReview = (root, presenter, ReviewedHunksBarView(presenter: presenter))
        }
        guard let review = hunkReview else { return }
        let hashes = document.hunks.map { hunk in
            if !hunk.patch.isEmpty { return ReviewedHunkHasher.hash(filePath: path, hunkPatch: hunk.patch) }
            let lines = document.lines.filter { $0.hunkIndex == hunk.index }.map(\.text)
            return ReviewedHunkHasher.hash(filePath: path, hunkLines: lines)
        }
        let presenter = review.presenter
        diff.reviewAction = { [weak presenter] index in
            guard let presenter, hashes.indices.contains(index) else { return nil }
            let hash = hashes[index]
            return DiffHunkBar.ReviewAction(isReviewed: presenter.isReviewed(hash)) {
                presenter.toggle(hash: hash, filePath: path)
            }
        }
        review.bar.onChange = { [weak presenter, weak diff] in
            guard let presenter, let diff, diff.shownPath == path, diff.document != nil else { return }
            let hidden =
                presenter.filterMode == .all
                ? []
                : Set(hashes.indices).subtracting(
                    presenter.visibleHunkIndices(for: hashes))
            diff.setHiddenReviewHunks(hidden)
            diff.reconfigureVisibleRows()
        }
        codePane.setReviewedHunksBar(review.bar)
        presenter.load(filePath: path, hashes: hashes)
    }
}
