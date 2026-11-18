import AppKit

/// A push button that runs a closure.
@MainActor
final class ActionButton: NSButton {
    var onPress: () -> Void

    init(title: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        self.title = title
        target = self
        action = #selector(press)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ActionButton is built in code") }

    @objc private func press() { onPress() }
}

/// A pop-up button that reports the chosen item to a closure.
@MainActor
final class ActionPopUpButton: NSPopUpButton {
    var onChange: (ActionPopUpButton) -> Void
    /// What the menu was last built from, so an unchanged list is not rebuilt on every refresh.
    var contentSignature: String?

    init(onChange: @escaping (ActionPopUpButton) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(changed)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ActionPopUpButton is built in code") }

    @objc private func changed() { onChange(self) }
    /// The represented object of the chosen item, when it is a string.
    var selectedValue: String? { selectedItem?.representedObject as? String }
    /// Selects the item that represents `value`; false when there is none.
    @discardableResult func select(value: String) -> Bool {
        guard let index = itemArray.firstIndex(where: { ($0.representedObject as? String) == value }) else {
            return false
        }
        selectItem(at: index)
        return true
    }
    func addItem(_ title: String, value: String?) {
        addItem(withTitle: title)
        lastItem?.representedObject = value
    }
}

/// A one-choice segmented control that reports the chosen segment to a closure.
@MainActor
final class ActionSegmentedControl: NSSegmentedControl {
    var onChange: (Int) -> Void

    init(labels: [String], onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() { setLabel(label, forSegment: index) }
        trackingMode = .selectOne
        target = self
        action = #selector(changed)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ActionSegmentedControl is built in code") }

    @objc private func changed() { onChange(selectedSegment) }
}
