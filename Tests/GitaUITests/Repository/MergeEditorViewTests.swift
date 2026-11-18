import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MergeEditorViewTests {
    /// A long file with one change near the top and one near the end, in an editor laid out in a window.
    private func editor() -> (MergeEditorView, NSWindow) {
        UITestSupport.bootstrap()
        let lines = (1...200).map { "line \($0)\n" }
        var ours = lines
        ours[2] = "ours 3\n"
        var theirs = lines
        theirs.insert(contentsOf: ["new a\n", "new b\n", "new c\n"], at: 150)
        var state = MergeEditorState()
        let document = ConflictDocument(
            path: "long.txt",
            base: ConflictVersion(objectID: "a", mode: .regular, text: lines.joined(), byteCount: 1),
            ours: ConflictVersion(objectID: "b", mode: .regular, text: ours.joined(), byteCount: 1),
            theirs: ConflictVersion(objectID: "c", mode: .regular, text: theirs.joined(), byteCount: 1),
            workingText: "", workingExists: true, isEditable: true, fingerprint: "f")
        state.loaded(MergeEditorState.Editing(document: document, operation: nil))
        let view = MergeEditorView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 500), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.layoutIfNeeded()
        view.apply(MergeEditorDisplay(state: state, isMutating: false, words: true))
        window.layoutIfNeeded()
        return (view, window)
    }

    @Test func scrollingOnePaneScrollsTheOthersPastTheInsertedLines() {
        let (view, window) = editor()
        defer { window.close() }
        view.resultPane.scroll(toLine: 170)
        #expect(abs(view.resultPane.topLine - 170) < 0.5)
        // Theirs has three more lines above line 170 of the base.
        #expect(abs(view.theirsPane.topLine - 173) < 0.5)
        #expect(abs(view.oursPane.topLine - 170) < 0.5)
        view.theirsPane.scroll(toLine: 10)
        #expect(abs(view.resultPane.topLine - 10) < 0.5)
        UITestSupport.render(view)
    }

    @Test func versionsShowTextImagesAndPlaceholders() throws {
        UITestSupport.bootstrap()
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let view = MergeVersionsView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        var chosen: [MergeSide] = []
        view.onChoose = { chosen.append($0) }
        func version(_ side: MergeSide, _ preview: MergePreview, chosen: Bool = false) -> MergeEditorDisplay.Version {
            MergeEditorDisplay.Version(
                side: side, title: side == .ours ? "Current" : "Incoming", detail: "detail", preview: preview,
                placeholder: "placeholder", action: "Use",
                symbol: chosen ? "checkmark.circle.fill" : "checkmark.circle",
                isChosen: chosen, isEnabled: true)
        }
        let ours = try #require(view.columns[.ours])
        let theirs = try #require(view.columns[.theirs])
        view.show(
            explanation: "why", versions: [version(.ours, .data(png)), version(.theirs, .data(Data([0])))],
            enabled: true)
        #expect(!ours.imageBox.isHidden && ours.caption.stringValue.hasPrefix("4 × 3"))
        #expect(!theirs.placeholderBox.isHidden && theirs.placeholder.stringValue == "placeholder")
        view.show(
            explanation: "why", versions: [version(.ours, .loading), version(.theirs, .note("note"), chosen: true)],
            enabled: false)
        #expect(!ours.placeholderBox.isHidden && !ours.button.isEnabled)
        view.show(
            explanation: "why", versions: [version(.ours, .deleted), version(.theirs, .text("a\nb\n"))], enabled: true)
        #expect(!theirs.textBox.isHidden && theirs.text.string == "a\nb\n")
        ours.button.performClick(nil)
        theirs.button.performClick(nil)
        #expect(chosen == [.ours, .theirs])
        UITestSupport.render(view)
    }

    @Test func navigatingRevealsTheCurrentChange() {
        let (view, window) = editor()
        defer { window.close() }
        view.resultPane.reveal(line: 150)
        let revealed = view.resultPane.topLine
        #expect(revealed > 100)
        // A line already in sight does not move the pane.
        view.resultPane.reveal(line: 151)
        #expect(view.resultPane.topLine == revealed)
        view.resultPane.reveal(line: 0)
        #expect(view.resultPane.topLine < 1)
    }
}
