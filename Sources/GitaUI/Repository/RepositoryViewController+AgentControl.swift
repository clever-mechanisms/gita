import AppKit
import GitaCore

/// Content-hashed Reviewed Hunks bar integration in the repository diff pane.
extension RepositoryViewController {
    static weak var sharedAgentControlFacade: AgentControlFacade?
    private static var fallbackAgentControlFacade: AgentControlFacade?
    private static var reviewedPresenters: [ObjectIdentifier: (root: URL, presenter: ReviewedHunksPresenter)] = [:]

    private var agentControlFacade: AgentControlFacade {
        if let shared = Self.sharedAgentControlFacade { return shared }
        if let existing = Self.fallbackAgentControlFacade { return existing }
        let created = AgentControlFacade()
        Self.fallbackAgentControlFacade = created
        return created
    }

    func resetReviewedHunks() {
        let key = ObjectIdentifier(self)
        Self.reviewedPresenters.removeValue(forKey: key)?.presenter.cancel()
        codePane.setReviewedHunksBar(nil)
    }

    func syncReviewedHunks() {
        guard let root = model.snapshot?.root, let path = model.selectedFile?.path, !model.diff.isEmpty else {
            codePane.setReviewedHunksBar(nil)
            return
        }
        let document = UnifiedDiff.parse(model.diff)
        let hashes = document.hunks.map { hunk in
            if !hunk.patch.isEmpty {
                return ReviewedHunkHasher.hash(filePath: path, hunkPatch: hunk.patch)
            }
            let lines = document.lines.filter { $0.hunkIndex == hunk.index }.map(\.text)
            return ReviewedHunkHasher.hash(filePath: path, hunkLines: lines)
        }
        guard !hashes.isEmpty else {
            codePane.setReviewedHunksBar(nil)
            return
        }
        let key = ObjectIdentifier(self)
        let presenter: ReviewedHunksPresenter
        if let existing = Self.reviewedPresenters[key], existing.root == root {
            presenter = existing.presenter
        } else {
            Self.reviewedPresenters[key]?.presenter.cancel()
            presenter = agentControlFacade.makeReviewedHunksPresenter(for: root)
            Self.reviewedPresenters[key] = (root, presenter)
            codePane.setReviewedHunksBar(agentControlFacade.makeReviewedHunksBar(presenter: presenter))
        }
        presenter.load(filePath: path, hashes: hashes)
    }
}
