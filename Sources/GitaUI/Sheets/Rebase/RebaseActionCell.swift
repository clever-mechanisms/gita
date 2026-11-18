import AppKit
import GitaCore

/// The action picker of one rebase row; it remembers which commit it edits.
@MainActor
final class RebaseActionPicker: NSPopUpButton { var commitID: String? }

/// The Action column's cell: a picker of pick, reword, edit, squash, fixup and drop.
@MainActor
final class RebaseActionCell: NSView {
    let picker = RebaseActionPicker(frame: .zero, pullsDown: false)
    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.controlSize = .small
        picker.font = TextLines.system(12)
        picker.addItems(withTitles: GitRebaseAction.allCases.map(\.localizedTitle))
        picker.setAccessibilityIdentifier("rebase.action")
        addSubview(picker)
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
            picker.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
}
