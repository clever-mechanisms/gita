import AppKit

/// The face for everything that is not code: labels, rows, buttons, titles (`Preference.interfaceFont`). Sizes and
/// weights stay those of the type scale (`Theme.body`…); only the face changes. Menus, alerts, popups and window titles
/// keep the macOS font. The choices are the system default (SF Pro) and the faces of the Code font list.
@MainActor
struct InterfaceFont: Hashable {
    /// nil = SF Pro; otherwise a Code font face used for the interface.
    let face: CodeFont?

    static let system = Self(face: nil)
    /// The menu, in groups: the default, then the terminal faces.
    static var groups: [[Self]] { [[system], CodeFont.allCases.map { Self(face: $0) }] }

    /// The stored value: `system` or `mono:<CodeFont>`. Anything else (faces earlier builds offered) is SF Pro.
    var id: String { face.map { "mono:" + $0.rawValue } ?? "system" }
    init(face: CodeFont?) { self.face = face }
    init(stored: String) {
        face = stored.hasPrefix("mono:") ? CodeFont(rawValue: String(stored.dropFirst(5))) : nil
    }

    /// Font names are not translated; the system choice says which face it is.
    var title: String {
        guard let face else { return String(localized: "System (\("SF Pro"))") }
        return face == .system ? "SF Mono" : face.title
    }

    /// Where the choice is stored; tests point it at a scratch suite.
    static var store: UserDefaults = Preference.store { didSet { cached = nil } }
    private static var cached: Self?
    static var current: Self {
        if let cached { return cached }
        let value = Self(stored: Preference.interfaceFont.string(store))
        cached = value
        return value
    }
    /// The face a live switch replaces (the previous choice), so its fonts are recognised in the open windows.
    private static var previousFamily: String?

    /// Saves the choice and re-fonts every open window in place (no restart): stored fonts on controls and text are
    /// swapped for the new face at the same size and weight, then views that draw text themselves redraw.
    static func apply(_ choice: Self) {
        guard choice != current else { return }
        previousFamily = current.make(12).familyName
        Preference.interfaceFont.set(choice.id, store)
        cached = choice
        TextLines.interfaceFontChanged()
        for window in NSApp.windows {
            if let root = window.contentView?.superview ?? window.contentView { refont(root) }
        }
        previousFamily = nil
        NotificationCenter.default.post(name: .gitaInterfaceFontChanged, object: nil)
    }

    /// A new font for this face; callers that draw often go through `TextLines.system`, which keeps one per size.
    func make(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        face?.make(size, weight: weight) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    // MARK: Live switch

    /// Every face this setting can produce, so a switch recognises the previous choice's fonts (and AppKit's own
    /// system-font defaults) and leaves code fonts and symbol fonts alone.
    private static func isInterface(_ font: NSFont) -> Bool {
        guard !TextLines.isCodeFont(font), let name = font.familyName else { return false }
        if name == previousFamily || name == TextLines.system(12).familyName { return true }
        // AppKit's own control fonts (SF Pro), but not SF Mono set elsewhere.
        return name.hasPrefix(".AppleSystemUIFont") && !name.contains("Mono")
    }
    private static let weights: [NSFont.Weight] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]
    /// The same size, weight and font features (monospaced digits) in the current face; nil for a non-interface font.
    static func replacement(for font: NSFont) -> NSFont? {
        guard isInterface(font) else { return nil }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let raw = (traits?[.weight] as? CGFloat) ?? 0
        let weight = weights.min { abs($0.rawValue - raw) < abs($1.rawValue - raw) } ?? .regular
        let next = TextLines.system(font.pointSize, weight: weight)
        guard let features = font.fontDescriptor.object(forKey: .featureSettings) else { return next }
        return NSFont(
            descriptor: next.fontDescriptor.addingAttributes([.featureSettings: features]), size: font.pointSize)
            ?? next
    }
    private static func refont(_ text: NSAttributedString) -> NSAttributedString? {
        guard text.length > 0 else { return nil }
        var changed = false
        let copy = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, let next = replacement(for: font) else { return }
            copy.addAttribute(.font, value: next, range: range)
            changed = true
        }
        return changed ? copy : nil
    }
    private static func refont(_ view: NSView) {
        // Popups and segmented controls keep the macOS control font, as on a fresh launch (like menus).
        if view is NSPopUpButton || view is NSSegmentedControl { return }
        refontControl(view)
        if let textView = view as? NSTextView { refontTextView(textView) }
        (view as? InterfaceFontRefreshing)?.interfaceFontChanged()
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.needsDisplay = true
        // A text field's own subviews (a search field's magnifier and clear buttons) draw glyphs, not text.
        guard !(view is NSTextField) else { return }
        for subview in view.subviews { refont(subview) }
    }
    /// A label's attributed text, else a control's font; then a field's placeholder and a button's title.
    private static func refontControl(_ view: NSView) {
        if let field = view as? NSTextField, !field.isEditable, hasFontAttribute(field.attributedStringValue),
            let text = refont(field.attributedStringValue)
        {
            field.attributedStringValue = text
        } else if let control = view as? NSControl, let font = control.font, let next = replacement(for: font) {
            control.font = next
        }
        if let field = view as? NSTextField, let placeholder = field.placeholderAttributedString,
            let text = refont(placeholder)
        {
            field.placeholderAttributedString = text
        }
        if let button = view as? NSButton, let text = refont(button.attributedTitle) { button.attributedTitle = text }
    }
    private static func hasFontAttribute(_ text: NSAttributedString) -> Bool {
        text.length > 0 && text.attribute(.font, at: 0, effectiveRange: nil) != nil
    }
    private static func refontTextView(_ textView: NSTextView) {
        if let font = textView.font, let next = replacement(for: font) { textView.font = next }
        if let storage = textView.textStorage, let text = refont(storage) { storage.setAttributedString(text) }
    }
}

/// Views that keep fonts outside AppKit's own properties (drawn parts, cached cells) swap them on a live switch.
@MainActor
protocol InterfaceFontRefreshing: AnyObject { func interfaceFontChanged() }

extension PartsButton: InterfaceFontRefreshing {
    func interfaceFontChanged() {
        parts = parts.map { part in
            guard case .text(let text, let font, let color) = part, let next = InterfaceFont.replacement(for: font)
            else { return part }
            return .text(text, font: next, color: color)
        }
    }
}

extension HistoryTextCell: InterfaceFontRefreshing {
    func interfaceFontChanged() { if let next = InterfaceFont.replacement(for: font) { font = next } }
}

extension Notification.Name {
    /// Posted after `InterfaceFont.apply`; views that keep a font from build time rebuild with `Theme` or
    /// `TextLines.system`.
    static let gitaInterfaceFontChanged = Notification.Name("dev.clevermechanisms.Gita.interfaceFontChanged")
}
