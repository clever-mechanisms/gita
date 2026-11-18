/// The Changes page's commit message (`CommitDraftController`).
extension AppModel {
    var commitDraft: CommitMessageDraft? { draftController.draft }
    var isCommitDraftCurrent: Bool { draftController.isCurrent }
    var commitMessage: String { draftController.text }

    func setCommitMessage(_ message: String) { draftController.setText(message) }
    func beginEditingCommitMessage() { draftController.beginEditing() }
    func endEditingCommitMessage() {
        if draftController.endEditing() { refresh() }
    }
    @discardableResult func flushCommitDraft() -> Bool { draftController.flush() }
}
