/// The code pane's header, inline hunk availability, and empty text: the shown path and hunk action eligibility
/// (a conflict opens in the merge editor instead).
struct CodePaneState: Equatable {
    struct Input {
        var isChanges: Bool
        var isStaged: Bool
        var path: String?
        var hasSelectedFile: Bool
        var selectedFileIsConflict: Bool
        var hasSelectedTreePath: Bool
        var hasCommit: Bool
        var isTreeReview: Bool
        var hasFiles: Bool
        var isWorkingTreeClean: Bool
        var isMutating: Bool
        var isDiffLoading: Bool
        /// The diff on screen can apply hunks.
        var canApplyHunks: Bool
        var ignoreWhitespace: Bool = false
    }

    var path: String
    var showsHunk: Bool
    var isStaged: Bool
    var canApplyDocumentHunks: Bool
    var showsWhitespaceNotice: Bool
    var emptyMessage: String

    init(_ input: Input) {
        path = input.path ?? ""
        let conflict = input.selectedFileIsConflict
        showsHunk = input.isChanges && !conflict
        isStaged = input.isStaged
        showsWhitespaceNotice =
            input.isChanges && !conflict && !input.isTreeReview && input.hasSelectedFile && input.ignoreWhitespace
        canApplyDocumentHunks =
            input.isChanges && !conflict && !input.isMutating && !input.isDiffLoading
            && input.hasSelectedFile && input.canApplyHunks && !input.ignoreWhitespace
        emptyMessage = Self.emptyMessage(input)
    }

    private static func emptyMessage(_ input: Input) -> String {
        if input.hasSelectedFile || input.hasSelectedTreePath { return String(localized: "No content") }
        if input.isChanges, !input.hasFiles {
            if input.isWorkingTreeClean { return String(localized: "Working tree clean") }
            return input.isStaged ? String(localized: "No staged changes") : String(localized: "No unstaged changes")
        }
        if input.hasCommit, !input.isTreeReview, !input.hasFiles { return String(localized: "No file changes") }
        return String(localized: "Select a file")
    }
}
