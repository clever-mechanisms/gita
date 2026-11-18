import AppKit
import GitaCore

/// Grouped "inset" form pieces for the Settings window: a titled rounded group of fixed-height rows, label on the
/// left and the control on the right, one baseline, no captions.
@MainActor
enum SettingsForm {
    static let rowHeight: CGFloat = 34
    static let inset: CGFloat = 12
    static let controlWidth: CGFloat = 240 // fits the longest font name ("Atkinson Hyperlegible Mono")
    static let markSize: CGFloat = 14
    static var labelFont: NSFont { TextLines.system(NSFont.systemFontSize) }

    static func label(_ text: String, color: NSColor = Theme.text, font: NSFont = labelFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    /// Short right-hand value ("rolottr", "2 working"), secondary colour.
    static func note(_ text: String = "") -> NSTextField {
        let note = label(text, color: Theme.secondaryText, font: Theme.body)
        note.alignment = .right
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return note
    }

    static func button(_ title: String, symbol: String, action: @escaping () -> Void) -> ActionButton {
        button(title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil), action: action)
    }

    static func button(_ title: String, image: NSImage?, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title: title, onPress: action)
        button.bezelStyle = .rounded
        button.image = image
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func popup(
        accessibility: String, onChange: @escaping (ActionPopUpButton) -> Void = { _ in }
    ) -> ActionPopUpButton {
        let popup = ActionPopUpButton(onChange: onChange)
        popup.setAccessibilityLabel(accessibility)
        popup.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        return popup
    }

    /// A segment per label, each led by its SF Symbol when `symbols` names one.
    static func segmented(
        _ labels: [String], symbols: [String] = [], accessibility: String, onChange: @escaping (Int) -> Void
    ) -> ActionSegmentedControl {
        let control = ActionSegmentedControl(labels: labels, onChange: onChange)
        for (index, symbol) in symbols.enumerated() where index < labels.count {
            control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.setAccessibilityLabel(accessibility)
        control.segmentDistribution = .fillEqually
        control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        return control
    }

    /// Cards side by side, sharing the pane's width equally.
    static func sideBySide(_ cards: [NSView]) -> NSStackView {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// A service's or app's mark before its name in a group title or row label; the name stays the accessible label.
    static func mark(_ label: NSTextField?, _ image: NSImage, _ name: String) {
        guard let label else { return }
        label.attributedStringValue = BrandMarks.label(
            image, name, font: label.font ?? Theme.body, color: label.textColor ?? Theme.text)
        label.setAccessibilityLabel(name)
    }
    /// An agent's mark before its name.
    static func mark(_ label: NSTextField, tool: AgentTool) {
        label.attributedStringValue = AgentMarks.label(
            tool, tool.displayName, font: label.font ?? Theme.body, color: label.textColor ?? Theme.text)
        label.setAccessibilityLabel(tool.displayName)
    }
}
