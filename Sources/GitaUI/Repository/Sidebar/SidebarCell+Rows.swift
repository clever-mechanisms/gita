import AppKit
import GitaCore

/// How each kind of sidebar row looks.
extension SidebarCell {
    private enum Indent {
        static let header: CGFloat = -23
        static let repository: CGFloat = 10
        static let checkout: CGFloat = 14
        static let nav: CGFloat = 18
        static let item: CGFloat = 30
        static let nestedItem: CGFloat = 42
        static let level: CGFloat = 12
    }
    /// A checkout lists at most this many agents in its tooltip.
    private static let listedAgents = 12

    func configure(_ row: RepositorySidebarView.Row) {
        reset()
        switch row {
        case .header(let text, let count, let sortable): configureHeader(text, count: count, sortable: sortable)
        case .repository(let repository, let expanded): configureRepository(repository, expanded: expanded)
        case .checkout(let checkout, _, let selected): configureCheckout(checkout, selected: selected)
        case .divider: configureDivider()
        case .nav(let nav): configureNav(nav)
        case .remote(let name, let branches, let expanded, let brand):
            configureRemote(name, branches: branches, expanded: expanded, brand: brand)
        case .reference(let reference): configureReference(reference)
        case .folder(let folder):
            configureGroup(
                folder.name, symbol: "folder",
                indent: (folder.nested ? Indent.nestedItem : Indent.item)
                    + CGFloat(folder.depth) * Indent.level, count: folder.expanded ? "" : "\(folder.count)",
                spokenCount: "\(folder.count)", expanded: folder.expanded)
        case .stash(let stash, _): configureStash(stash)
        case .empty(let text): configureEmpty(text)
        }
        updateFilterButtons()
    }

    private static func expansionWord(_ expanded: Bool) -> String {
        expanded ? String(localized: "expanded") : String(localized: "collapsed")
    }

    private func configureHeader(_ text: String, count: String, sortable: Bool) {
        setChevron(.none)
        icon.isHidden = true
        leading.constant = Indent.header
        sort.isHidden = !sortable
        title.attributedStringValue = NSAttributedString(
            string: text.localizedUppercase,
            attributes: [
                .font: TextLines.system(11, weight: .semibold), .foregroundColor: Theme.secondaryText, .kern: 0.45,
                .paragraphStyle: Deck.truncatingTail,
            ])
        trailing.stringValue = count
        trailing.textColor = Theme.tertiaryText
        icon.image = nil
        setAccessibilityLabel(text)
    }

    private func configureRepository(_ repository: RepositorySidebarView.Repository, expanded: Bool) {
        leading.constant = Indent.repository
        setChevron(.init(expanded: expanded))
        icon.setSymbol("folder", size: 12, color: Deck.adaptive(light: Theme.accent, dark: Theme.working))
        title.stringValue = repository.name
        title.font = Theme.title
        title.lineBreakMode = .byTruncatingMiddle
        trailing.stringValue = repository.error ?? repository.badge
        trailing.textColor =
            repository.error != nil
            ? Theme.failure : repository.badgeIsChange ? Theme.needsInputText : Theme.accentText
        toolTip = repository.root.path
        setAccessibilityLabel(
            [
                repository.name, repository.badge, Self.expansionWord(expanded),
            ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func configureCheckout(_ checkout: RepositorySidebarView.Checkout, selected: Bool) {
        leading.constant = Indent.checkout
        setChevron(.none)
        chevron.isHidden = true
        icon.image = nil
        let crowd = WindowAgents.crowd(checkout.sessions)
        // The lead's mark stands where the icon was; it turns while any agent here works.
        if let crowd {
            let working = checkout.sessions.contains { $0.state == .working }
            mark.agent = AgentMarkState(tool: crowd.lead.tool, state: working ? .working : crowd.state)
            mark.isHidden = false
        } else {
            icon.setSymbol(
                checkout.isMain ? "arrow.triangle.branch" : Deck.worktreeSymbol, size: 10, color: Theme.tertiaryText)
        }
        title.stringValue = checkout.branch
        title.font = selected ? Theme.bodyEmphasis : Theme.body
        title.lineBreakMode = .byTruncatingMiddle
        // The open checkout is bold. A second line only for an agent; the icon already says main checkout (branch) or
        // linked worktree.
        titleCenter.isActive = crowd == nil
        titleTop.isActive = crowd != nil
        subtitle.isHidden = crowd == nil
        if let crowd {
            subtitle.textColor =
                crowd.state == .idle || crowd.state == .done
                ? Theme.secondaryText : WindowAgents.stateColor(crowd.state)
            subtitle.stringValue = WindowAgents.crowdLine(crowd, naming: false)
        } else {
            subtitle.stringValue = ""
        }
        showCheckoutTrailing(checkout)
        if checkout.isLoading { showSpinner() }
        toolTip = ([checkout.path] + Self.agentLines(checkout, crowd: crowd)).joined(separator: "\n")
        let spoken =
            crowd.map { WindowAgents.crowdLine($0) }
            ?? (checkout.isMain ? String(localized: "Main checkout") : String(localized: "Worktree"))
        setAccessibilityLabel(
            [
                checkout.branch, spoken, checkout.isLoading ? String(localized: "Loading Repository") : checkout.meta,
                selected ? String(localized: "current") : "",
            ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Commits ahead, else a linked worktree's folder where it differs from the branch (as in the Worktrees group).
    private func showCheckoutTrailing(_ checkout: RepositorySidebarView.Checkout) {
        let folder = URL(fileURLWithPath: checkout.path).lastPathComponent
        if checkout.meta.isEmpty, !checkout.isMain, folder != checkout.branch {
            trailing.stringValue = folder
            trailing.textColor = Theme.tertiaryText
            trailing.lineBreakMode = .byTruncatingMiddle
            trailing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            trailing.stringValue = checkout.meta
            trailing.textColor = Theme.secondaryText
        }
    }

    /// Every agent here, one per line, when there is more than one (the subtitle shows only the lead).
    private static func agentLines(_ checkout: RepositorySidebarView.Checkout, crowd: WindowAgents.Crowd?) -> [String] {
        guard checkout.sessions.count > 1 else { return crowd.map { [WindowAgents.crowdLine($0)] } ?? [] }
        return checkout.sessions.prefix(listedAgents).map { WindowAgents.menuLine($0) }
            + (checkout.sessions.count > listedAgents ? ["…"] : [])
    }

    private func configureDivider() {
        setChevron(.none)
        icon.isHidden = true
        icon.image = nil
        title.stringValue = ""
        trailing.stringValue = ""
        rule.isHidden = false
    }

    private func configureNav(_ nav: RepositorySidebarView.Nav) {
        leading.constant = Indent.nav
        setChevron(nav.expansion)
        if nav.expansion == .none { chevron.isHidden = true }
        // Deployments carries Vercel's mark: the solid triangle in ink (black in light, white in dark).
        let deployments = nav.target == .page(.deployments)
        icon.setSymbol(
            nav.symbol, size: deployments ? 10 : 11, color: deployments ? Theme.text : Theme.secondaryText)
        title.stringValue = nav.title
        title.font = nav.selected ? Theme.bodyEmphasis : Theme.body
        title.textColor =
            nav.selected ? Theme.text : Deck.adaptive(light: Theme.text, dark: Theme.text.withAlphaComponent(0.86))
        trailing.stringValue = nav.count
        // A page names its shortcut ("Pull Requests  ⌥⌘4").
        if case .page(let page) = nav.target {
            toolTip =
                (page == .history ? ShortcutCommand.allCommits : page.section.flatMap(ShortcutCommand.page))?
                .toolTip
        } else {
            toolTip = nil
        }
        setAccessibilityLabel([nav.title, nav.count].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// A remote: its host's own mark (GitHub, GitLab, Bitbucket) where Gita has one, else the network symbol.
    private func configureRemote(_ name: String, branches: Int, expanded: Bool, brand: BrandMarks.Brand?) {
        configureGroup(
            name, symbol: "network", indent: Indent.item, count: branches > 0 ? "\(branches)" : "",
            spokenCount: "\(branches)", expanded: expanded)
        if let brand { icon.image = BrandMarks.image(brand, size: 12, color: Theme.secondaryText) }
    }

    /// A remote or a folder of branches.
    private func configureGroup(
        _ name: String, symbol: String, indent: CGFloat, count: String, spokenCount: String, expanded: Bool
    ) {
        leading.constant = indent
        setChevron(.init(expanded: expanded))
        icon.setSymbol(symbol, size: 10, color: symbol == "folder" ? Theme.tertiaryText : Theme.secondaryText)
        title.stringValue = name
        title.font = Theme.body
        trailing.stringValue = count
        trailing.textColor = Theme.tertiaryText
        toolTip = nil
        setAccessibilityLabel([name, spokenCount, Self.expansionWord(expanded)].joined(separator: ", "))
    }

    private func configureStash(_ stash: GitStash) {
        leading.constant = Indent.item
        setChevron(.none)
        chevron.isHidden = true
        icon.setSymbol("archivebox", size: 10, color: Theme.tertiaryText)
        title.stringValue = stash.subject
        trailing.stringValue = ""
        toolTip = stash.ref
        setAccessibilityLabel(stash.subject)
    }

    private func configureEmpty(_ text: String) {
        leading.constant = Indent.item
        setChevron(.none)
        icon.isHidden = true
        title.stringValue = text
        title.textColor = Theme.secondaryText
        trailing.stringValue = ""
    }

    // MARK: References

    private func configureReference(_ row: RepositorySidebarView.ReferenceRow) {
        let reference = row.reference
        let marks = row.marks
        self.marks = marks
        // A remote branch sits under its remote, named without the remote ("main" under origin).
        let nested = reference.kind == .remote
        leading.constant = (nested ? Indent.nestedItem : Indent.item) + CGFloat(marks.depth) * Indent.level
        setChevron(.none)
        chevron.isHidden = true
        // Branches go without a symbol (the group and the folders already say what they are); the current one keeps
        // its check, tags their tag.
        let symbol = reference.kind == .tag ? "tag" : reference.isCurrent ? "checkmark" : nil
        icon.setSymbol(
            symbol, size: 10, color: reference.isCurrent ? Theme.checkedOut : Theme.tertiaryText)
        title.stringValue = marks.label ?? (nested ? RemoteBranchName.branchName(reference) : reference.name)
        title.font = reference.isCurrent || row.selected ? Theme.bodyEmphasis : Theme.body
        title.textColor = reference.isCurrent ? Theme.checkedOut : Theme.text
        showReferenceTrailing(row)
        // A hidden branch stays listed, faded, so it can be shown again.
        if marks.hidden { title.textColor = Theme.tertiaryText }
        if let agent = row.agent {
            mark.agent = agent
            mark.isHidden = false
            icon.isHidden = true
        }
        toolTip = Self.referenceToolTip(row)
        setAccessibilityLabel(Self.referenceLabel(row))
    }

    private static func referenceLabel(_ row: RepositorySidebarView.ReferenceRow) -> String {
        let reference = row.reference
        let marks = row.marks
        let spoken = reference.isCurrent ? String(localized: "\(reference.name), current branch") : reference.name
        return [
            spoken, marks.pinned ? String(localized: "pinned") : nil,
            marks.hidden ? String(localized: "Hidden in the graph") : nil,
            marks.only ? String(localized: "Shown alone in the graph") : nil,
            row.comments > 0 ? String(localized: "\(row.comments) unresolved preview comments") : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// Unresolved preview comments, else a production marker on the production branch, else the worktree's folder.
    private func showReferenceTrailing(_ row: RepositorySidebarView.ReferenceRow) {
        if row.comments > 0 {
            trailing.attributedStringValue = Self.comments(row.comments)
        } else if row.isProduction, let image = Deck.symbol("triangle.fill", size: 8, color: Theme.tertiaryText) {
            let attachment = NSTextAttachment()
            attachment.image = image
            trailing.attributedStringValue = NSAttributedString(attachment: attachment)
        } else if let worktree = row.marks.worktree, worktree != row.reference.name {
            // The folder gives way to the branch name.
            trailing.stringValue = worktree
            trailing.textColor = Theme.tertiaryText
            trailing.lineBreakMode = .byTruncatingMiddle
            trailing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            trailing.stringValue = ""
        }
    }

    private static func comments(_ count: Int) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let image = Deck.symbol("text.bubble", size: 9.5, color: Theme.needsInputText) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(
            NSAttributedString(
                string: "\(count)", attributes: [.font: Theme.caption, .foregroundColor: Theme.needsInputText]))
        return text
    }

    private static func referenceToolTip(_ row: RepositorySidebarView.ReferenceRow) -> String {
        let marks = row.marks
        return [
            row.reference.fullName, marks.worktree.map { _ in String(localized: "Checked out in a worktree") },
            marks.hidden
                ? String(localized: "Hidden in the graph")
                : marks.only ? String(localized: "Shown alone in the graph") : nil,
            row.isProduction ? String(localized: "Production branch") : nil,
            row.comments > 0 ? String(localized: "\(row.comments) unresolved preview comments") : nil,
        ].compactMap { $0 }.joined(separator: "\n")
    }
}
