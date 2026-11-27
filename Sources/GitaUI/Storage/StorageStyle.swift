import AppKit

/// Shared Apple-native visual building blocks for the Storage & Health window.
@MainActor
enum StorageStyle {
    private struct BannerSpec {
        let symbol: String
        let text: String
        let color: NSColor
        let fill: NSColor
    }

    static var cardSurface: NSColor { Deck.adaptive(light: Theme.inset, dark: Theme.toolbar) }
    static var cardBorder: NSColor { Theme.separator }

    static var blue: NSColor { Theme.running }
    static var green: NSColor { Theme.success }
    static var purple: NSColor { Theme.merged }
    static var orange: NSColor { Theme.needsInputText }
    static var indigo: NSColor { Theme.working }
    static var teal: NSColor { Theme.checkedOut }

    static func card(cornerRadius: CGFloat = 10) -> FillView {
        let view = FillView(color: cardSurface)
        view.borderColor = cardBorder
        view.cornerRadius = cornerRadius
        return view
    }

    static func iconBadge(
        _ symbol: String, tint: NSColor, boxSize: CGFloat = 30, symbolSize: CGFloat = 14, cornerRadius: CGFloat = 7
    ) -> NSView {
        let box = FillView(color: tint.withAlphaComponent(0.14))
        box.cornerRadius = cornerRadius
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setAccessibilityElement(false)
        let icon = Deck.icon(symbol, size: symbolSize, weight: .semibold, color: tint)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        box.addSubview(icon)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: boxSize),
            box.heightAnchor.constraint(equalToConstant: boxSize),
            icon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    static func pill(
        _ text: String, fill: NSColor, textColor: NSColor, monospacedDigits: Bool = false
    ) -> NSView {
        let container = FillView(color: fill)
        container.cornerRadius = 6
        let font =
            monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            : TextLines.system(10.5, weight: .medium)
        let label = Deck.label(text, font: font, color: textColor)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        Deck.pin(label, in: container, insets: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        return container
    }

    static func statusPill(_ text: String, tone: StorageHealthCardModel.StatusTone) -> NSView {
        switch tone {
        case .positive:
            pill(text, fill: Theme.success.withAlphaComponent(0.14), textColor: Theme.success, monospacedDigits: true)
        case .warning:
            pill(
                text, fill: Theme.needsInput.withAlphaComponent(0.14), textColor: Theme.needsInputText,
                monospacedDigits: true)
        case .neutral:
            pill(text, fill: Theme.control, textColor: Theme.secondaryText, monospacedDigits: true)
        }
    }

    static func reclaimablePill(_ bytes: UInt64, presenter: StoragePresenter) -> NSView {
        let text = String(localized: "\(presenter.formatBytes(bytes)) reclaimable")
        return statusPill(text, tone: .warning)
    }

    static func toneColor(_ tone: StorageHealthCardModel.IconTone) -> NSColor {
        switch tone {
        case .blue: blue
        case .green: green
        case .purple: purple
        case .orange: orange
        case .indigo: indigo
        }
    }

    static func nodeToneColor(_ tone: StorageOutlineNode.Tone) -> NSColor {
        switch tone {
        case .blue: blue
        case .teal: teal
        case .accent: Theme.accent
        case .indigo: indigo
        case .green: green
        case .orange: orange
        case .neutral: Theme.secondaryText
        }
    }

    static func actionButton(
        _ title: String, symbol: String? = nil, style: PartsButton.Background = .quiet,
        accessibility: String? = nil, onClick: @escaping () -> Void
    ) -> PartsButton {
        let button = PartsButton([], background: style, accessibility: accessibility ?? title, onClick: onClick)
        button.fixedHeight = 26
        button.horizontalPadding = 10
        button.spacing = 5
        button.cornerRadius = 6
        setButtonContent(button, title: title, symbol: symbol, accessibility: accessibility ?? title)
        return button
    }

    static func setButtonContent(
        _ button: PartsButton, title: String, symbol: String? = nil, accessibility: String? = nil
    ) {
        let textColor: NSColor = button.background == .accent ? .white : Theme.text
        let iconColor: NSColor = button.background == .accent ? .white : Theme.secondaryText
        var parts = [PartsButton.Part]()
        if let symbol { parts.append(.symbol(symbol, color: iconColor, size: 11.5)) }
        parts.append(.text(title, font: TextLines.system(12, weight: .medium), color: textColor))
        button.parts = parts
        button.setAccessibilityLabel(accessibility ?? title)
    }

    static func iconButton(
        symbol: String, accessibility: String, tint: NSColor = Theme.secondaryText, onClick: @escaping () -> Void
    ) -> PartsButton {
        let button = PartsButton(
            [.symbol(symbol, color: tint, size: 12)], background: .hover, accessibility: accessibility, onClick: onClick
        )
        button.fixedHeight = 24
        button.horizontalPadding = 5
        button.cornerRadius = 5
        button.toolTip = accessibility
        return button
    }

    static func heroHeader(
        symbol: String, title: String, heroMetric: String, subtitle: String, controls: [NSView]
    ) -> NSView {
        let icon = iconBadge(symbol, tint: Theme.accent, boxSize: 34, symbolSize: 16, cornerRadius: 8)
        let titleLabel = Deck.label(title, font: TextLines.system(14, weight: .semibold))
        let heroLabel = Deck.label(
            heroMetric, font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            color: Theme.secondaryText)
        let topLine = Deck.hstack([titleLabel, heroLabel], spacing: 8)
        let subLabel = Deck.caption(subtitle)
        let titleBlock = Deck.vstack([topLine, subLabel], spacing: 2)
        let controlsRow = Deck.hstack(controls, spacing: 8)
        return Deck.hstack([icon, titleBlock, Deck.spacer(), controlsRow], spacing: 12)
    }

    static func proportionBar(
        fraction: Double, tint: NSColor, width: CGFloat? = nil, height: CGFloat = 5
    ) -> NSView {
        let clamped = min(1, max(0, fraction))
        let track = FillView(color: Theme.control)
        track.cornerRadius = height / 2
        track.translatesAutoresizingMaskIntoConstraints = false
        track.setAccessibilityElement(false)
        var constraints: [NSLayoutConstraint] = [track.heightAnchor.constraint(equalToConstant: height)]
        if let width { constraints.append(track.widthAnchor.constraint(equalToConstant: width)) }
        if clamped > 0 {
            let fill = FillView(color: tint)
            fill.cornerRadius = height / 2
            fill.translatesAutoresizingMaskIntoConstraints = false
            fill.setAccessibilityElement(false)
            track.addSubview(fill)
            constraints += [
                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: clamped),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return track
    }

    static func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func scopeSegmentedControl(
        labels: [String], symbols: [String], onChange: @escaping (Int) -> Void
    ) -> ActionSegmentedControl {
        let control = ActionSegmentedControl(labels: labels, onChange: onChange)
        for (index, name) in symbols.enumerated() where index < labels.count {
            control.setImage(Deck.template(name, size: 12, weight: .medium), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        return control
    }

    static func layoutHeaderChrome(headerBar: NSView, content: NSView, in rootView: NSView) {
        let headerDivider = Deck.separator()
        for subview in [headerBar, headerDivider, content] as [NSView] {
            rootView.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 48),
            headerDivider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            content.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
    }

    static func pinTopInset(_ view: NSView, in container: NSView, top: CGFloat = 18) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
        ])
    }

    /// Configures a borderless scroll view whose flipped document always tracks the full viewport width.
    @discardableResult
    static func configureScrollView(_ scroll: NSScrollView) -> FlippedView {
        scroll.contentView = PixelAlignedClipView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return document
    }

    static func banner(_ state: HealthActionState) -> NSView? {
        let spec: BannerSpec? =
            switch state {
            case .idle: nil
            case .running(let text):
                BannerSpec(
                    symbol: "arrow.triangle.2.circlepath", text: text, color: Theme.running,
                    fill: Theme.running.withAlphaComponent(0.10))
            case .succeeded(let text):
                BannerSpec(
                    symbol: "checkmark.circle.fill", text: text, color: Theme.success,
                    fill: Theme.success.withAlphaComponent(0.10))
            case .failed(let text):
                BannerSpec(
                    symbol: "exclamationmark.triangle.fill", text: text, color: Theme.failure,
                    fill: Theme.failure.withAlphaComponent(0.10))
            }
        guard let spec else { return nil }
        let container = FillView(color: spec.fill)
        container.borderColor = spec.color.withAlphaComponent(0.28)
        container.cornerRadius = 8
        let icon = Deck.icon(spec.symbol, size: 13, weight: .semibold, color: spec.color)
        icon.setAccessibilityElement(false)
        let label = Deck.wrapping(spec.text, font: Theme.body, color: spec.color)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = spec.text
        let row = Deck.hstack([icon, label], spacing: 8)
        Deck.pin(row, in: container, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        return container
    }
}
