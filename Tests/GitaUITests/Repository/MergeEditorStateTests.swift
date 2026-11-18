import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite struct MergeEditorStateTests {
    static func version(_ text: String?, mode: GitFileMode = .regular, bytes: Int = 10) -> ConflictVersion {
        ConflictVersion(objectID: String(repeating: "a", count: 40), mode: mode, text: text, byteCount: bytes)
    }

    static func document(
        base: String? = "a\nb\nc\n", ours: String? = "A\nb\nc\n", theirs: String? = "a\nb\nC\n",
        editable: Bool = true, mode: GitFileMode = .regular, working: String? = "a\n<<<<<<<\n"
    ) -> ConflictDocument {
        ConflictDocument(
            path: "Sources/file.swift", base: base.map { version($0) }, ours: ours.map { version($0, mode: mode) },
            theirs: theirs.map { version($0, mode: mode) }, workingText: working, workingExists: working != nil,
            isEditable: editable, fingerprint: "fingerprint")
    }

    /// What Save & Stage would write, as text.
    func saved(_ state: MergeEditorState) -> String {
        switch state.resolution() {
        case .none: "none"
        case .failure: "tooLarge"
        case .success(.ours): ".ours"
        case .success(.theirs): ".theirs"
        case .success(.base): ".base"
        case .success(.edited(let text)): ".edited(\(text.debugDescription))"
        }
    }

    static let merge = GitOperationState(kind: .merge, identity: "merge")
    static let rebase = GitOperationState(kind: .rebase, identity: "rebase")

    @Test func wordingFollowsTheOperation() {
        let merge = MergeWording(operation: Self.merge)
        let rebase = MergeWording(operation: Self.rebase)
        #expect(merge.title(.ours) == "Current" && merge.title(.theirs) == "Incoming")
        #expect(rebase.title(.ours) == "Onto" && rebase.title(.theirs) == "Replayed commit")
        #expect(merge.useTitle(.theirs) == "Use Incoming" && rebase.useTitle(.theirs) == "Use Commit")
        #expect(rebase.useTitle(.ours) == "Use Onto" && merge.useTitle(.ours) == "Use Current")
        for side in MergeSide.allCases {
            #expect(!merge.explanation(side).isEmpty && !rebase.explanation(side).isEmpty)
        }
        #expect(MergeWording.describe(nil) == "Deleted on this side")
        #expect(MergeWording.describe(Self.version(nil, mode: .symlink)) == "Symbolic link")
        #expect(MergeWording.describe(Self.version(nil, mode: .submodule)).hasPrefix("Submodule at aaaaaaaaaaaa"))
        #expect(MergeWording.describe(Self.version(nil, bytes: 2_048)).hasPrefix("Binary or not UTF-8"))
        #expect(MergeWording.describe(Self.version("x")).hasPrefix("Text"))
    }

    @Test func aTextConflictIsMergedChangeByChangeThenSaved() {
        var state = MergeEditorState()
        #expect(state.path == nil && !state.canAct && saved(state) == "none")
        state.load(path: "Sources/file.swift")
        #expect(state.isBusy && state.path == "Sources/file.swift")
        state.loaded(MergeEditorState.Editing(document: Self.document(), operation: Self.merge))
        #expect(state.canAct && !state.canSave)
        #expect(state.editing?.current == 0)
        state.perform(.navigate(forward: true))
        #expect(state.editing?.current == 1)
        state.perform(.nonConflicting(nil))
        #expect(state.canSave)
        #expect(saved(state) == ".edited(\"A\\nb\\nC\\n\")")
        state.perform(.revert(chunk: 1))
        #expect(!state.canSave)
        state.perform(.ignore(.theirs, chunk: 1))
        state.perform(.apply(.ours, chunk: 0))
        #expect(saved(state) == ".edited(\"A\\nb\\nc\\n\")")
        state.perform(.whole(.theirs))
        #expect(saved(state) == ".theirs")
        state.perform(.reset)
        state.perform(.edit("merged\n"))
        #expect(saved(state) == ".edited(\"merged\\n\")")
        let refused1 = state.perform(.choose(.ours))
        #expect(!refused1)
        let saving = state.beginSaving()
        #expect(saving?.document.path == "Sources/file.swift" && state.isBusy && !state.canAct)
        let refused2 = state.perform(.reset)
        #expect(!refused2)
        state.saveFailed("stale")
        #expect(state.message == "stale" && state.canAct)
        _ = state.beginSaving()
        state.saved()
        #expect(state.path == "Sources/file.swift" && state.editing == nil && state.beginSaving() == nil)
        state.close()
        #expect(state.path == nil)
    }

    @Test func aSimpleConflictResolvesInOneStep() {
        var state = MergeEditorState()
        let document = Self.document(base: "a\nb\n", ours: "A\nb\n", theirs: "a\nB\n")
        state.loaded(MergeEditorState.Editing(document: document, operation: Self.merge))
        state.perform(.simple(chunk: 0))
        #expect(saved(state) == ".edited(\"A\\nB\\n\")")
        #expect(MergeEditorState.simpleResult(document) == "A\nB\n")
        #expect(MergeEditorState.simpleResult(Self.document(ours: "x\n", theirs: "y\n")) == nil)
        #expect(MergeEditorState.simpleResult(Self.document(ours: nil)) == nil)
        #expect(
            MergeEditorState.simpleSummary(resolved: 0, of: 2) == "No conflict is simple enough to merge on its own")
        #expect(MergeEditorState.simpleSummary(resolved: 1, of: 2) == "Merged 1 of 2 conflicted files")
        var all = MergeEditorState()
        all.loaded(MergeEditorState.Editing(document: document, operation: nil))
        all.perform(.simpleAll)
        #expect(all.canSave)
    }

    private func versions(_ state: MergeEditorState) -> (String, [MergeEditorDisplay.Version]) {
        guard
            case .versions(let explanation, let versions) = MergeEditorDisplay(
                state: state, isMutating: false, words: true
            ).body
        else { return ("", []) }
        return (explanation, versions)
    }

    @Test func aDeletionShowsTheFileBesideItsDeletion() {
        var state = MergeEditorState()
        let deleted = Self.document(ours: nil, theirs: "kept\n", editable: false)
        state.loaded(MergeEditorState.Editing(document: deleted, operation: Self.merge))
        #expect(!state.canSave)
        let refused3 = state.perform(.apply(.ours, chunk: 0))
        #expect(!refused3)
        var (explanation, shown) = versions(state)
        #expect(explanation.contains("deleted"))
        #expect(shown.map(\.preview) == [.deleted, .text("kept\n")])
        #expect(shown.map(\.action) == ["Delete File", "Keep File"])
        #expect(shown.map(\.symbol) == ["trash", "checkmark.circle"])
        #expect(shown.first?.placeholder == "Deleted in Current")
        state.perform(.choose(.ours))
        #expect(saved(state) == ".ours")
        state.perform(.choose(.theirs))
        #expect(saved(state) == ".theirs")
        (_, shown) = versions(state)
        #expect(shown.map(\.isChosen) == [false, true])
        #expect(shown.last?.symbol == "checkmark.circle.fill")
        let display = MergeEditorDisplay(state: state, isMutating: false, words: true)
        #expect(display.status == "Version chosen" && display.canSave && !display.isText)
    }

    @Test func binaryBytesArriveAfterTheConflictOpens() {
        var state = MergeEditorState()
        let binary = Self.document(ours: nil, theirs: nil, editable: false)
        var document = binary
        document.ours = Self.version(nil, bytes: 4)
        document.theirs = Self.version(nil, bytes: MergeEditorState.maximumTextSize + 1)
        state.loaded(MergeEditorState.Editing(document: document, operation: nil))
        var (explanation, shown) = versions(state)
        #expect(explanation.contains("line by line"))
        #expect(shown.first?.preview == .loading && shown.first?.placeholder == "Reading the file…")
        if case .note = shown.last?.preview {} else { Issue.record("An oversized side is described") }
        #expect(shown.map(\.action) == ["Use Current", "Use Incoming"])
        state.showPreview(.data(Data([1, 2])), side: .ours, fingerprint: "another")
        #expect(versions(state).1.first?.preview == .loading)
        state.showPreview(.data(Data([1, 2])), side: .ours, fingerprint: "fingerprint")
        (_, shown) = versions(state)
        #expect(shown.first?.preview == .data(Data([1, 2])))
        #expect(shown.first?.placeholder.hasPrefix("Binary") == true)
        state.perform(.choose(.ours))
        _ = state.beginSaving()
        state.showPreview(.note("gone"), side: .theirs, fingerprint: "fingerprint")
        state.saveFailed("stale")
        state.showPreview(.note("again"), side: .theirs, fingerprint: "fingerprint")
        #expect(state.editing?.previews[.theirs] == .note("again"))
        state.close()
        state.showPreview(.deleted, side: .ours, fingerprint: "fingerprint")
        #expect(MergePreview(Self.version(nil, mode: .symlink)) == .note("Symbolic link"))
    }

    @Test func aSubmoduleCannotBeChosenHere() {
        var submodule = MergeEditorState()
        submodule.loaded(
            MergeEditorState.Editing(document: Self.document(editable: false, mode: .submodule), operation: nil))
        let refused4 = submodule.perform(.choose(.ours))
        #expect(!refused4)
        let (text, shown) = versions(submodule)
        #expect(text.contains("submodule"))
        #expect(shown.allSatisfy { !$0.isEnabled })
    }

    @Test func messagesCoverLoadingFailureAndSaved() {
        var state = MergeEditorState()
        state.loadFailed("ignored while closed")
        #expect(state.path == nil)
        state.load(path: "a")
        var display = MergeEditorDisplay(state: state, isMutating: false, words: true)
        #expect(
            display.body
                == .message(.init(title: "Reading the conflict…", detail: "", canReload: false, canReopen: false)))
        state.loadFailed("gone")
        display = MergeEditorDisplay(state: state, isMutating: false, words: true)
        #expect(display.error == "gone")
        if case .message(let message) = display.body { #expect(message.canReload && message.detail == "gone") }
        state.report("ignored")
        state.saved()
        state.saveFailed("ignored")
        #expect(state.message == "gone")
        #expect(MergeEditorDisplay().path.isEmpty)
    }

    @Test func theWorkingFileCanBecomeTheResult() {
        var state = MergeEditorState()
        state.loaded(MergeEditorState.Editing(document: Self.document(working: "fixed elsewhere\n"), operation: nil))
        #expect(MergeEditorDisplay(state: state, isMutating: false, words: true).canUseWorking)
        state.perform(.working)
        #expect(saved(state) == ".edited(\"fixed elsewhere\\n\")")
        var absent = MergeEditorState()
        absent.loaded(MergeEditorState.Editing(document: Self.document(working: nil), operation: nil))
        #expect(!MergeEditorDisplay(state: absent, isMutating: false, words: true).canUseWorking)
        let refused = absent.perform(.working)
        #expect(!refused)
    }

    @Test func aResultOverTheLimitIsNotSaved() {
        var state = MergeEditorState()
        state.loaded(MergeEditorState.Editing(document: Self.document(), operation: nil))
        state.perform(.edit(String(repeating: "x", count: MergeEditorState.maximumTextSize + 1)))
        #expect(saved(state) == "tooLarge")
        #expect(MergeEditorError.resultTooLarge.errorDescription?.isEmpty == false)
        state.report("too large")
        #expect(state.message == "too large")
    }

    @Test func displayShowsWhatIsLeftAndWhatCanBeDone() {
        var state = MergeEditorState()
        let document = Self.document(base: "a\nb\nc\nd\n", ours: "A\nb\nc\nD1\n", theirs: "a\nb\nC\nD2\n")
        state.loaded(MergeEditorState.Editing(document: document, operation: Self.rebase))
        var display = MergeEditorDisplay(state: state, isMutating: false, words: true)
        #expect(display.isText && display.canAct && !display.canSave)
        #expect(display.status == "Conflicts left: 1 · Changes left: 1")
        #expect(display.canApplyAll && display.canApplyNonConflicting[.ours] == true)
        #expect(display.canApplyNonConflicting[.theirs] == false)
        #expect(display.wording.isRebase)
        display = MergeEditorDisplay(state: state, isMutating: true, words: true)
        #expect(!display.canAct && !display.canApplyAll)
        state.perform(.whole(.ours))
        display = MergeEditorDisplay(state: state, isMutating: false, words: true)
        #expect(display.status == "All changes processed" && display.isDone && display.canSave)
    }

    @Test func presenterShadesChunksAndBuildsTheGutters() throws {
        var session = MergeSession(base: "a\nb\nc\nd\n", ours: "A\nb\nd\n", theirs: "a\nb\nc\nd\ne\n")
        var display = MergePresenter.present(session, current: 0, words: true)
        #expect(display.ours.text == "A\nb\nd\n" && display.theirs.text == "a\nb\nc\nd\ne\n")
        #expect(display.result.text == "a\nb\nc\nd\n")
        #expect(display.ours.lineCount == 3 && display.result.lineCount == 4)
        #expect(display.ours.bands.map(\.tint) == [.modified, .deleted])
        #expect(display.theirs.bands.map(\.tint) == [.added])
        #expect(display.result.bands.first?.isCurrent == true)
        #expect(display.ours.words == [MergeWord(range: 0..<1, tint: .modified)])
        #expect(display.left.count == 2 && display.right.count == 1 && display.left.allSatisfy(\.isPending))
        #expect(display.marks.isEmpty)
        session.apply(.ours, chunk: 0)
        display = MergePresenter.present(session, current: nil, words: false)
        #expect(display.marks == [MergeGutterMark(chunk: 0, line: 0, kind: .revert, tint: .modified)])
        #expect(display.ours.words.isEmpty && display.ours.bands.first?.isDone == true)
        let conflict = MergeSession(base: "a\nb\n", ours: "A\nb\n", theirs: "a\nB\n")
        let simple = MergePresenter.present(conflict, current: nil, words: true)
        #expect(simple.marks.map(\.kind) == [.simple])
        #expect(simple.result.bands.map(\.tint) == [.conflict])
        var copy = simple
        copy[.result] = MergePaneDisplay()
        #expect(copy[.result].text.isEmpty && copy[.ours] == simple.ours && copy[.theirs] == simple.theirs)
    }
}
