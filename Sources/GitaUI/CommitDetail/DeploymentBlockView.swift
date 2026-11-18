import AppKit
import GitaCore

/// One deployment in the Commit tab (Open ↗ · Copy · Inspect · Logs), built from a `DeploymentBlockModel`.
@MainActor
enum DeploymentBlockView {
    private static let triangleIcon: CGFloat = 10
    private static let rowIcon: CGFloat = 11

    static func make(_ model: DeploymentBlockModel, context: CommitDetailContext) -> NSView {
        var rows: [NSView] = [header(model)]
        if let address = model.address { rows.append(addressRow(address, model: model, context: context)) }
        if model.isLive, let production = context.input.vercel?.production {
            rows += ProductionRows.domainRows(production, context: context, showsDomain: !model.showsMainURL)
        }
        if let preview = model.branchPreview { rows.append(branchPreviewRow(preview.branch, url: preview.url)) }
        if let comments = model.comments { rows.append(commentsRow(comments)) }
        if let rollout = model.rollout { rows += ProductionRows.rolloutRows(rollout, context: context) }
        if model.isFailure {
            if let platform = model.platform { rows.append(ProductionRows.platformRow(platform)) }
            rows.append(BuildLogView.make(context.buildLog(model.item)))
        }
        if let actions = actionsRow(model, context: context) { rows.append(actions) }
        if context.expanded.contains(model.item.id), let loader = context.loader {
            rows.append(ProviderDetailView(item: model.item, loader: loader))
        }
        let view = DetailRows.block(rows)
        view.identifier = NSUserInterfaceItemIdentifier(model.item.id)
        view.setAccessibilityLabel(HistoryChips.deploymentDescription(model.item))
        return view
    }

    private static func header(_ model: DeploymentBlockModel) -> NSView {
        let item = model.item
        var views: [NSView] = [
            Deck.icon("triangle.fill", size: triangleIcon, color: model.isLive ? Theme.success : Theme.text),
            Deck.label(model.title, font: Theme.bodyEmphasis),
            Deck.label(model.stateText, font: Theme.body, color: Theme.color(for: item.state)),
            Deck.caption(model.age), Deck.spacer(),
        ]
        if let url = model.address?.url {
            views.append(PartsButton.openButton(String(localized: "Open"), small: true) { url })
        }
        return Deck.hstack(views, spacing: 8)
    }

    private static func addressRow(
        _ address: DeploymentBlockModel.Address, model: DeploymentBlockModel, context: CommitDetailContext
    ) -> NSView {
        let url = address.url
        let label = DetailRows.address(url.host ?? url.absoluteString)
        label.toolTip = address.tooltip
        var more: NSView?
        if address.moreDomains > 0 {
            let caption = Deck.caption("+\(address.moreDomains)")
            caption.toolTip = address.moreTooltip
            more = caption
        }
        var links: [NSView] = [label, more, Deck.spacer(), DetailRows.copyLink(url)].compactMap { $0 }
        if address.inspectable {
            let item = model.item
            let open = context.expanded.contains(item.id)
            links.append(
                PartsButton.link(open ? String(localized: "Hide") : String(localized: "Inspect")) {
                    context.toggle(item.id)
                })
            links.append(PartsButton.link(String(localized: "Logs")) { context.openLogs(item) })
        }
        return Deck.hstack(links, spacing: 10)
    }

    private static func branchPreviewRow(_ branch: String, url: URL) -> NSView {
        let address = DetailRows.address(url.host ?? url.absoluteString, color: Theme.secondaryText)
        address.toolTip = String(localized: "Always the latest deployment of \(branch)")
        let caption = Deck.caption(String(localized: "Branch"))
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        return Deck.hstack(
            [caption, address, Deck.spacer(), DetailRows.copyLink(url), DetailRows.openLink(url)], spacing: 8)
    }

    private static func commentsRow(_ comments: DeploymentBlockModel.Comments) -> NSView {
        Deck.hstack(
            [
                Deck.icon("text.bubble", size: rowIcon, color: Theme.needsInputText),
                Deck.label(
                    String(localized: "\(comments.count) unresolved comments"), font: Theme.body,
                    color: Theme.needsInputText),
                Deck.spacer(), DetailRows.openLink(comments.target),
            ], spacing: 6)
    }

    private static func actionsRow(_ model: DeploymentBlockModel, context: CommitDetailContext) -> NSView? {
        guard !model.actions.isEmpty, let perform = context.vercelAction else { return nil }
        let item = model.item
        let buttons: [NSView] = model.actions.map { action in
            PartsButton.quiet(VercelActions.shortTitle(action), symbol: VercelActions.symbol(action)) {
                perform(action, item)
            }
        }
        return Deck.hstack(buttons + [Deck.spacer()], spacing: 6)
    }
}
