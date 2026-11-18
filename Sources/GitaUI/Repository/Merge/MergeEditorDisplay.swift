import Foundation
import GitaCore

/// What the merge editor shows for its state: the toolbar's status, the headers, the panes or the choice of a
/// version, and which controls work now. Pure.
struct MergeEditorDisplay: Equatable {
    struct Message: Equatable {
        var title: String
        var detail: String
        var canReload: Bool
        var canReopen: Bool
    }

    /// One side of a conflict that is a choice of versions: its content and the button that keeps it.
    struct Version: Equatable {
        var side: MergeSide
        var title: String
        var detail: String
        var preview: MergePreview
        /// Shown in place of content: why there is none.
        var placeholder: String
        var action: String
        var symbol: String
        var isChosen: Bool
        var isEnabled: Bool
    }

    enum Body: Equatable {
        case message(Message)
        case text(MergeTextDisplay)
        case versions(explanation: String, versions: [Version])
    }

    var path = ""
    var status = ""
    var isDone = false
    var wording = MergeWording(operation: nil)
    var body = Body.message(Message(title: "", detail: "", canReload: false, canReopen: false))
    var canAct = false
    var canSave = false
    var isText = false
    var canApplyNonConflicting: [MergeSide: Bool] = [:]
    var canApplyAll = false
    var canSimple = false
    var canUseWorking = false
    var isBusy = false
    var error: String?

    init() {}

    init(state: MergeEditorState, isMutating: Bool, words: Bool) {
        path = state.path ?? ""
        isBusy = state.isBusy
        error = state.message
        canAct = state.canAct && !isMutating
        canSave = state.canSave && !isMutating
        guard let editing = state.editing else {
            body = .message(Self.message(state.phase))
            return
        }
        wording = editing.wording
        isDone = editing.isComplete
        switch editing.content {
        case .text(let session):
            isText = true
            body = .text(MergePresenter.present(session, current: editing.current, words: words))
            status = Self.status(session)
            canApplyAll = canAct && session.hasPendingChanges(from: nil)
            for side in MergeSide.allCases {
                canApplyNonConflicting[side] = canAct && session.hasPendingChanges(from: side)
            }
            canSimple = canAct && session.offersSimple
            canUseWorking = canAct && editing.workingText != nil
        case .choice(let chosen):
            status = chosen == nil ? String(localized: "Choose a version") : String(localized: "Version chosen")
            body = .versions(explanation: Self.explanation(editing.document), versions: Self.versions(editing, chosen))
        }
    }

    private static func status(_ session: MergeSession) -> String {
        if session.isComplete { return String(localized: "All changes processed") }
        var parts: [String] = []
        if session.pendingConflicts > 0 {
            parts.append(String(localized: "Conflicts left: \(session.pendingConflicts)"))
        }
        if session.pendingChanges > 0 { parts.append(String(localized: "Changes left: \(session.pendingChanges)")) }
        return parts.joined(separator: " · ")
    }

    private static func message(_ phase: MergeEditorState.Phase) -> Message {
        switch phase {
        case .loading:
            Message(title: String(localized: "Reading the conflict…"), detail: "", canReload: false, canReopen: false)
        case .loadFailed(_, let message):
            Message(
                title: String(localized: "Cannot open this conflict"), detail: message, canReload: true,
                canReopen: false)
        case .saved:
            Message(
                title: String(localized: "Resolved and staged"),
                detail: String(localized: "Reopen brings the conflict back exactly as Git left it."), canReload: false,
                canReopen: true)
        case .closed, .editing, .saving, .saveFailed:
            Message(title: "", detail: "", canReload: false, canReopen: false)
        }
    }

    private static func explanation(_ document: ConflictDocument) -> String {
        if document.ours == nil || document.theirs == nil {
            return String(localized: "Changed on one side and deleted on the other. Keep the file or delete it.")
        }
        if document.ours?.mode == .submodule || document.theirs?.mode == .submodule {
            return String(localized: "Resolve a submodule in its own repository, then stage the commit to keep.")
        }
        return String(localized: "This file cannot be merged line by line. Choose the version to keep.")
    }

    private static func versions(_ editing: MergeEditorState.Editing, _ chosen: MergeSide?) -> [Version] {
        let document = editing.document
        let deletion = document.ours == nil || document.theirs == nil
        return MergeSide.allCases.map { side in
            let version = side == .ours ? document.ours : document.theirs
            let title = editing.wording.title(side)
            let preview = editing.previews[side] ?? MergePreview(version)
            let action: (String, String) =
                if version == nil {
                    (String(localized: "Delete File"), "trash")
                } else if deletion {
                    (String(localized: "Keep File"), "checkmark.circle")
                } else {
                    (editing.wording.useTitle(side), "checkmark.circle")
                }
            return Version(
                side: side, title: title, detail: editing.wording.explanation(side), preview: preview,
                placeholder: placeholder(preview, version: version, title: title), action: action.0,
                symbol: chosen == side ? "checkmark.circle.fill" : action.1, isChosen: chosen == side,
                isEnabled: editing.canUse(side))
        }
    }

    private static func placeholder(_ preview: MergePreview, version: ConflictVersion?, title: String) -> String {
        switch preview {
        case .text: ""
        case .data: MergeWording.describe(version)
        case .loading: String(localized: "Reading the file…")
        case .deleted: String(localized: "Deleted in \(title)")
        case .note(let note): note
        }
    }
}
