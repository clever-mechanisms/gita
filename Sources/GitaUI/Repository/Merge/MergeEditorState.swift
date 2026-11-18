import Foundation
import GitaCore

/// One thing the merge editor can do to the conflict it shows.
enum MergeAction: Equatable, Sendable {
    case apply(MergeSide, chunk: Int)
    case ignore(MergeSide, chunk: Int)
    case revert(chunk: Int)
    case simple(chunk: Int)
    case simpleAll
    case nonConflicting(MergeSide?)
    case whole(MergeSide)
    /// The file as it is in the working tree, resolved in another editor.
    case working
    case reset
    case edit(String)
    case choose(MergeSide)
    case navigate(forward: Bool)
}

/// What a side of a conflict that is not merged line by line shows: its text, its bytes (an image when they make
/// one), a note, or that the side deleted the file.
enum MergePreview: Equatable, Sendable {
    case text(String)
    case data(Data)
    case loading
    case deleted
    case note(String)

    /// What can be shown at once; bytes are read afterwards.
    init(_ version: ConflictVersion?) {
        guard let version else {
            self = .deleted
            return
        }
        if version.mode == .submodule || version.mode == .symlink {
            self = .note(MergeWording.describe(version))
        } else if let text = version.text {
            self = .text(text)
        } else if version.byteCount > MergeEditorState.maximumTextSize {
            self = .note(MergeWording.describe(version))
        } else {
            self = .loading
        }
    }
}

/// The merge editor's conflict: loaded, worked on, saved. Pure; `MergeEditorController` runs the reads and writes.
struct MergeEditorState {
    /// Text both sides have is merged change by change; anything else (a deletion, binary data, a link, a
    /// submodule) is resolved by choosing one side's whole version.
    enum Content {
        case text(MergeSession)
        case choice(MergeSide?)
    }

    /// A conflict being worked on, with the operation it belongs to.
    struct Editing {
        var document: ConflictDocument
        var operation: GitOperationState?
        var content: Content
        /// The chunk the arrows and the highlight are on.
        var current: Int?
        /// Each side's content, for a conflict that is a choice of versions.
        var previews: [MergeSide: MergePreview] = [:]

        init(document: ConflictDocument, operation: GitOperationState?) {
            self.document = document
            self.operation = operation
            if Self.isMergeable(document), let ours = document.ours?.text, let theirs = document.theirs?.text {
                let session = MergeSession(base: document.base?.text ?? "", ours: ours, theirs: theirs)
                content = .text(session)
                current = session.nextChunk(from: nil, forward: true)
            } else {
                content = .choice(nil)
                previews = [.ours: MergePreview(document.ours), .theirs: MergePreview(document.theirs)]
            }
        }

        static func isMergeable(_ document: ConflictDocument) -> Bool {
            let versions = [document.base, document.ours, document.theirs]
            return document.isEditable && document.ours != nil && document.theirs != nil
                && versions.allSatisfy { $0.map { $0.mode.isFile && $0.text != nil } ?? true }
        }

        var wording: MergeWording { MergeWording(operation: operation) }

        /// The sides whose bytes are still to be read for their preview.
        var unreadPreviews: [(side: MergeSide, version: ConflictVersion)] {
            [(MergeSide.ours, document.ours), (.theirs, document.theirs)].compactMap { side, version in
                guard previews[side] == .loading, let version else { return nil }
                return (side, version)
            }
        }

        /// The working file's text, when there is one to put in the result.
        var workingText: String? { document.workingExists ? document.workingText : nil }

        func canUse(_ side: MergeSide) -> Bool {
            (side == .ours ? document.ours : document.theirs)?.mode != .submodule
        }

        var isComplete: Bool {
            switch content {
            case .text(let session): session.isComplete
            case .choice(let side): side != nil
            }
        }
    }

    enum Phase {
        case closed
        case loading(path: String)
        case loadFailed(path: String, message: String)
        case editing(Editing)
        case saving(Editing)
        case saveFailed(Editing, message: String)
        /// Saved and staged; the file stays shown until the selection moves on.
        case saved(path: String)
    }

    static let maximumTextSize = 8 * 1_024 * 1_024

    private(set) var phase = Phase.closed

    var path: String? {
        switch phase {
        case .closed: nil
        case .loading(let path), .loadFailed(let path, _), .saved(let path): path
        case .editing(let editing), .saving(let editing), .saveFailed(let editing, _): editing.document.path
        }
    }

    var editing: Editing? {
        switch phase {
        case .editing(let editing), .saving(let editing), .saveFailed(let editing, _): editing
        case .closed, .loading, .loadFailed, .saved: nil
        }
    }

    /// The editing state that accepts changes now (not while saving).
    private var editable: Editing? {
        switch phase {
        case .editing(let editing), .saveFailed(let editing, _): editing
        case .closed, .loading, .loadFailed, .saving, .saved: nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .saving: true
        case .closed, .loadFailed, .editing, .saveFailed, .saved: false
        }
    }

    var message: String? {
        switch phase {
        case .loadFailed(_, let message), .saveFailed(_, let message): message
        case .closed, .loading, .editing, .saving, .saved: nil
        }
    }

    var canAct: Bool { editable != nil }
    var canSave: Bool { editable?.isComplete == true }

    /// What Save & Stage writes: a whole side as Git has it, or the merged text.
    func resolution() -> Result<ConflictResolution, MergeEditorError>? {
        guard let editing = editable, editing.isComplete else { return nil }
        switch editing.content {
        case .choice(let side): return side.map { .success($0 == .ours ? .ours : .theirs) }
        case .text(let session):
            if let side = session.wholeSide { return .success(side == .ours ? .ours : .theirs) }
            let text = session.resultText
            guard text.utf8.count <= Self.maximumTextSize else { return .failure(.resultTooLarge) }
            return .success(.edited(text))
        }
    }

    /// The result when every change in `document` conflicts with nothing or is a simple conflict; nil otherwise.
    static func simpleResult(_ document: ConflictDocument) -> String? {
        guard Editing.isMergeable(document), let ours = document.ours?.text, let theirs = document.theirs?.text else {
            return nil
        }
        var session = MergeSession(base: document.base?.text ?? "", ours: ours, theirs: theirs)
        session.applyNonConflicting(from: nil)
        session.resolveAllSimple()
        return session.isComplete ? session.resultText : nil
    }

    static func simpleSummary(resolved: Int, of total: Int) -> String {
        if resolved == 0 { return String(localized: "No conflict is simple enough to merge on its own") }
        return String(localized: "Merged \(resolved) of \(total) conflicted files")
    }

    // MARK: Transitions

    mutating func load(path: String) { phase = .loading(path: path) }
    mutating func loaded(_ editing: Editing) { phase = .editing(editing) }
    mutating func loadFailed(_ message: String) {
        guard case .loading(let path) = phase else { return }
        phase = .loadFailed(path: path, message: message)
    }
    mutating func close() { phase = .closed }

    /// Starts Save & Stage: the editing state it writes, nil when there is nothing to save.
    mutating func beginSaving() -> Editing? {
        guard canSave, let editing = editable else { return nil }
        phase = .saving(editing)
        return editing
    }
    mutating func saved() {
        guard case .saving(let editing) = phase else { return }
        phase = .saved(path: editing.document.path)
    }
    mutating func saveFailed(_ message: String) {
        guard case .saving(let editing) = phase else { return }
        phase = .saveFailed(editing, message: message)
    }
    /// A side's bytes arrived, for the conflict that asked for them.
    mutating func showPreview(_ preview: MergePreview, side: MergeSide, fingerprint: String) {
        guard var editing, editing.document.fingerprint == fingerprint else { return }
        editing.previews[side] = preview
        switch phase {
        case .editing: phase = .editing(editing)
        case .saving: phase = .saving(editing)
        case .saveFailed(_, let message): phase = .saveFailed(editing, message: message)
        case .closed, .loading, .loadFailed, .saved: break
        }
    }

    /// A message about the open conflict that is not a failed save (a result too large to write).
    mutating func report(_ message: String) {
        guard let editing = editable else { return }
        phase = .saveFailed(editing, message: message)
    }

    /// Applies `action`; false when nothing can change now.
    @discardableResult mutating func perform(_ action: MergeAction) -> Bool {
        guard var editing = editable else { return false }
        switch (editing.content, action) {
        case (.choice, .choose(let side)):
            guard editing.canUse(side) else { return false }
            editing.content = .choice(side)
        case (.text, .choose): return false
        case (.text(var session), .working):
            guard let text = editing.workingText else { return false }
            session.setResultText(text)
            editing.content = .text(session)
        case (.text(var session), _):
            Self.apply(action, to: &session, current: &editing.current)
            editing.content = .text(session)
        case (.choice, _): return false
        }
        phase = .editing(editing)
        return true
    }

    private static func apply(_ action: MergeAction, to session: inout MergeSession, current: inout Int?) {
        switch action {
        case .apply(let side, let chunk):
            session.apply(side, chunk: chunk)
            current = chunk
        case .ignore(let side, let chunk):
            session.ignore(side, chunk: chunk)
            current = chunk
        case .revert(let chunk):
            session.revert(chunk: chunk)
            current = chunk
        case .simple(let chunk):
            session.resolveSimple(chunk: chunk)
            current = chunk
        case .simpleAll: session.resolveAllSimple()
        case .nonConflicting(let side): session.applyNonConflicting(from: side)
        case .whole(let side): session.useWhole(side)
        case .reset: session.reset()
        case .edit(let text): session.setResultText(text)
        case .navigate(let forward): current = session.nextChunk(from: current, forward: forward)
        case .choose, .working: break
        }
    }
}

enum MergeEditorError: Error, Equatable, LocalizedError {
    case resultTooLarge

    var errorDescription: String? { String(localized: "The result is larger than 8 MiB. Shorten it before saving.") }
}
