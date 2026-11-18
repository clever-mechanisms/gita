import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite struct SheetsRebasePlanEditorTests {
    private static let base = SheetsSupport.commit(SheetsSupport.objectID("0"), subject: "Base")
    private static let ids = ["1", "2", "3"].map { SheetsSupport.objectID(Character($0)) }

    private static func plan(
        _ ids: [String] = ids, head: String? = nil, base: GitCommit = base
    )
        -> GitInteractiveRebasePlan
    {
        GitInteractiveRebasePlan(
            base: base, headID: head ?? ids.last ?? "", branch: "main",
            commits: ids.map { SheetsSupport.commit($0, subject: "Commit \($0.prefix(1))") }, identity: "identity")
    }

    private static func editor() -> RebasePlanEditor {
        var editor = RebasePlanEditor()
        editor.load(plan())
        return editor
    }

    @Test func acceptsOnlyAReviewedLinearRange() {
        let baseID = Self.base.id
        #expect(RebasePlanEditor.accepts(Self.plan(), baseID: baseID))
        #expect(!RebasePlanEditor.accepts(Self.plan(), baseID: SheetsSupport.objectID("9")))
        #expect(!RebasePlanEditor.accepts(Self.plan([]), baseID: baseID))
        #expect(!RebasePlanEditor.accepts(Self.plan(["short"]), baseID: baseID))
        #expect(!RebasePlanEditor.accepts(Self.plan([baseID]), baseID: baseID))
        #expect(!RebasePlanEditor.accepts(Self.plan(head: Self.ids[0]), baseID: baseID))
        #expect(!RebasePlanEditor.accepts(Self.plan([Self.ids[0], Self.ids[0]]), baseID: baseID))
        let many = (0..<501).map { String(format: "%040x", $0 + 1) }
        #expect(!RebasePlanEditor.accepts(Self.plan(many), baseID: baseID))
    }

    @Test func movingAndChangingActions() {
        var editor = Self.editor()
        #expect(!editor.isDirty && !editor.hasPlanChanges && !editor.orderChanged)
        #expect(editor.validation == nil)
        let result1 = editor.move(from: 0, to: 0)
        let result2 = editor.move(from: 0, to: 3)
        #expect(!result1 && !result2)
        let result3 = editor.move(from: 0, to: 2)
        #expect(result3)
        #expect(editor.steps.map(\.commitID) == [Self.ids[1], Self.ids[2], Self.ids[0]])
        #expect(editor.orderChanged && editor.isDirty)
        #expect(editor.index(of: Self.ids[0]) == 2 && editor.step(Self.ids[0])?.action == .pick)
        let result4 = editor.setAction(.drop, for: "missing")
        #expect(!result4)
        let result5 = editor.setAction(.drop, for: Self.ids[1])
        #expect(result5)
        #expect(editor.dropCount == 1)
        editor.load(Self.plan())
        #expect(!editor.isDirty && editor.dropCount == 0)
    }

    @Test func squashOrFixupCannotLead() {
        var editor = Self.editor()
        let result6 = editor.setAction(.squash, for: Self.ids[0])
        #expect(result6)
        #expect(editor.validation == "The first retained commit cannot be Squash or Fixup.")
        let result7 = editor.setAction(.drop, for: Self.ids[0])
        #expect(result7)
        let result8 = editor.setAction(.fixup, for: Self.ids[1])
        #expect(result8)
        #expect(editor.validation == "The first retained commit cannot be Squash or Fixup.")
        let result9 = editor.setAction(.pick, for: Self.ids[1])
        #expect(result9)
        #expect(editor.validation == nil)
        #expect(RebasePlanEditor().validation == "No commits to replay.")
    }

    @Test func rewordedMessages() {
        var editor = Self.editor()
        let id = Self.ids[1]
        #expect(!editor.needsMessage(id))
        let result10 = editor.setAction(.reword, for: id)
        #expect(result10)
        #expect(editor.needsMessage(id))
        #expect(editor.validation == "Loading the message for 2222222222…")
        editor.messageLoaded(.failure(SheetsFailure("unreadable")), for: id)
        #expect(editor.validation == "Message for 2222222222: unreadable")
        editor.clearMessageError(id)
        editor.messageLoaded(.success(String(repeating: "m", count: RebasePlanEditor.messageLimit + 1)), for: id)
        #expect(editor.messageErrors[id] == "The complete message exceeds 64 KiB.")
        editor.messageLoaded(.success("bad\u{0}message"), for: id)
        #expect(editor.messageErrors[id] == "The commit message contains an unsupported NUL character.")
        editor.messageLoaded(.success("Original\n"), for: id)
        #expect(editor.message(for: id) == "Original\n" && editor.messageErrors[id] == nil)
        #expect(!editor.needsMessage(id))
        editor.setDraft("Original\n", for: id)
        #expect(editor.drafts.isEmpty)
        editor.setDraft("  \n", for: id)
        #expect(editor.validation == "Enter a complete message for 2222222222.")
        editor.setDraft("Reworded\n", for: id)
        #expect(editor.validation == nil && editor.isDirty)
        #expect(editor.submittedSteps.map(\.message) == [nil, "Reworded\n", nil])
        editor.setDraft("nul\u{0}", for: id)
        #expect(editor.validation == "The message for 2222222222 must fit in 64 KiB.")
        editor.load(Self.plan())
        #expect(editor.originals[id] == "Original\n" && editor.drafts.isEmpty)
    }

    @Test func combinedMessagesAreBounded() {
        var editor = Self.editor()
        let large = String(repeating: "m", count: 60 * 1_024)
        for id in Self.ids {
            let result11 = editor.setAction(.reword, for: id)
            #expect(result11)
            editor.messageLoaded(.success("x"), for: id)
            editor.setDraft(large, for: id)
        }
        #expect(editor.validation == nil)
        var crowded = RebasePlanEditor()
        let ids = (1...20).map { String(format: "%040x", $0) }
        crowded.load(Self.plan(ids))
        for id in ids {
            let result12 = crowded.setAction(.reword, for: id)
            #expect(result12)
            crowded.messageLoaded(.success("x"), for: id)
            crowded.setDraft(large, for: id)
        }
        #expect(crowded.validation == "Combined replacement messages exceed 1 MiB.")
    }

    @Test(arguments: [
        ("", NSRange(location: 0, length: 0), "Hello", true),
        ("Hello", NSRange(location: 0, length: 5), "", true),
        ("Hello", NSRange(location: 9, length: 1), "x", false),
        ("", NSRange(location: 0, length: 0), "a\u{0}b", false),
        ("", NSRange(location: 0, length: 0), String(repeating: "x", count: 64 * 1_024 + 1), false),
        (String(repeating: "x", count: 64 * 1_024), NSRange(location: 0, length: 0), "y", false),
    ])
    func editLimits(current: String, range: NSRange, replacement: String, expected: Bool) {
        #expect(RebasePlanEditor.acceptsEdit(of: current, range: range, replacement: replacement) == expected)
    }

    @Test func statusLines() {
        var editor = Self.editor()
        let idle = RebasePlanEditor.Progress()
        #expect(editor.status(.idle, idle) == SheetStatus(message: ""))
        #expect(editor.status(.applying(refusedClose: false), idle) == SheetStatus(message: "Rebasing…", isBusy: true))
        #expect(
            editor.status(.applying(refusedClose: true), idle).message
                == "Wait for the rebase to finish or pause.")
        #expect(
            editor.status(.idle, .init(review: .loading))
                == SheetStatus(message: "Loading commits…", isBusy: true))
        #expect(
            editor.status(.idle, .init(review: .stale("stale")))
                == SheetStatus(message: "stale\nReload to review this range again.", isError: true))
        #expect(
            RebasePlanEditor().status(.idle, .init(review: .stale("stale")))
                == SheetStatus(message: "stale", isError: true))
        #expect(
            editor.status(.idle, .init(inputError: "too long"))
                == SheetStatus(message: "too long", isError: true))
        _ = editor.setAction(.drop, for: Self.ids[0])
        #expect(editor.status(.idle, idle).message == "1 commits will be dropped.")
        _ = editor.setAction(.drop, for: Self.ids[1])
        _ = editor.setAction(.drop, for: Self.ids[2])
        #expect(editor.status(.idle, idle).message == "All 3 commits will be dropped.")
        _ = editor.setAction(.pick, for: Self.ids[2])
        _ = editor.setAction(.reword, for: Self.ids[2])
        #expect(
            editor.status(.idle, .init(messagesPending: true))
                == SheetStatus(message: "Loading the message for 3333333333…", isBusy: true))
        #expect(editor.status(.idle, idle).isError)
    }

    @Test func messageQueueLimitsConcurrentReads() {
        var queue = RebaseMessageQueue<String>(limit: 2)
        #expect(queue.isIdle)
        for id in ["a", "b", "c", "d", "a"] { queue.enqueue(id) }
        #expect(queue.waiting == ["a", "b", "c", "d"])
        var launched: [String] = []
        let launch: (String) -> String = { id in
            launched.append(id)
            return "read-" + id
        }
        queue.start(where: { $0 != "b" }, launch: launch)
        #expect(launched == ["a", "c"] && queue.running == ["a": "read-a", "c": "read-c"])
        #expect(queue.contains("a") && queue.contains("d") && !queue.contains("b"))
        queue.start(where: { _ in true }, launch: launch)
        #expect(launched == ["a", "c"])
        queue.finished("a")
        queue.start(where: { _ in true }, launch: launch)
        #expect(launched == ["a", "c", "d"])
        #expect(queue.removeAll().sorted() == ["read-c", "read-d"])
        #expect(queue.isIdle && RebaseMessageQueue<String>().limit == 2)
    }

    @Test func onlyACurrentReviewCanBeApplied() {
        typealias Review = RebasePlanEditor.Review
        #expect(Review.loading.isLoading && !Review.current.isLoading)
        #expect(Review.stale("refused").error == "refused")
        #expect(Review.unread.error == nil && Review.current.error == nil && Review.loading.error == nil)
        let editor = Self.editor()
        #expect(editor.status(.idle, .init(review: .unread)) == SheetStatus(message: ""))
        #expect(editor.status(.idle, .init(review: .current)) == SheetStatus(message: ""))
    }
}
