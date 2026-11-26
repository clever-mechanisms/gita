import AppKit

/// Reports edits without rebuilding the field or disturbing its insertion point.
@MainActor
final class ActionEditorField: NSTextField, NSTextFieldDelegate {
    private let changed: (String) -> Void
    var began: (() -> Void)?
    var ended: (() -> Void)?

    init(_ value: String, label: String, width: CGFloat = 200, changed: @escaping (String) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        stringValue = value
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingMiddle
        setAccessibilityLabel(label)
        delegate = self
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ActionEditorField is built in code") }

    func controlTextDidBeginEditing(_: Notification) { began?() }
    func controlTextDidChange(_: Notification) { changed(stringValue) }
    func controlTextDidEndEditing(_: Notification) { ended?() }
}
