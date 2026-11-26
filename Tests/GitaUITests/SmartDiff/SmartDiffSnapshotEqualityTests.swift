import Foundation
import GitaCore
import Testing

@testable import GitaUI

struct SmartDiffSnapshotEqualityTests {
    private func snapshot(
        _ document: DiffDocument, path: String = "file", options: SmartDiffOptions = .init(),
        expanded: Set<Int> = [], structured: StructuredDiffResult = .unsupported
    ) -> SmartDiffSnapshot {
        SmartDiffSource(filePath: path, document: document, related: [:], structured: structured)
            .snapshot(options: options, expanded: expanded)
    }

    @Test func equalityTracksTheDocumentIncludingPatchIdentity() {
        let document = DiffDocument(
            lines: [.init(text: "+new", old: "", new: "1", kind: "+", hunkIndex: 0)],
            hunks: [.init(index: 0, patch: "first patch")], canApplyHunks: true)
        let original = snapshot(document)
        #expect(original == snapshot(document))
        var changed = document
        changed.hunks[0].patch = "replacement patch"
        #expect(original != snapshot(changed))
        changed = document
        changed.hunks[0].index = 1
        #expect(original != snapshot(changed))
        changed = document
        changed.canApplyHunks = false
        #expect(original != snapshot(changed))
        changed = document
        changed.lines[0].text = "+replacement"
        #expect(original != snapshot(changed))
    }

    @Test func equalityTracksPresentationInputs() {
        let document = UnifiedDiff.parse("")
        let original = snapshot(document)
        #expect(original != snapshot(document, path: "renamed"))
        #expect(original != snapshot(document, options: .init(hideNoise: false)))
        #expect(original != snapshot(document, expanded: [0]))
        #expect(original != snapshot(document, structured: .fallback(format: .json, reason: "invalid")))
    }
}
