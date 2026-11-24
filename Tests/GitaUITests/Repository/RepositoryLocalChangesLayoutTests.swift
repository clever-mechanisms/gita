import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Local Changes · Layout & Composer", .serialized)
struct RepositoryLocalChangesLayoutTests {
    @Test func changesSectionCollapsesHistoryByDefaultAndRemembersDividersPerSection() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        fixture.window.setContentSize(NSSize(width: 1_100, height: 820))
        controller.view.layoutSubtreeIfNeeded()
        controller.settleLayout()
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.model.section == .history)
        #expect(!controller.verticalSplit.isSubviewCollapsed(controller.historyTop))
        let historyLeftWidth = controller.filesSplit.arrangedSubviews.first?.frame.width ?? 0
        #expect(historyLeftWidth >= RepositoryLayout.filePaneMinimum)

        controller.model.section = .changes
        try await fixture.wait("changes layout") {
            controller.verticalSplit.isSubviewCollapsed(controller.historyTop)
        }
        controller.view.layoutSubtreeIfNeeded()
        let changesLeftWidth = controller.filesSplit.arrangedSubviews.first?.frame.width ?? 0
        #expect(changesLeftWidth >= RepositoryLayout.changesFilePaneMinimum)
        #expect(abs(controller.codePane.frame.height - controller.detailBody.frame.height) <= 1)
        #expect(controller.commitFooter.countLabel.frame.width > 0)
        #expect(
            controller.commitFooter.countLabel.contentCompressionResistancePriority(for: .horizontal) == .required)

        // Switching back to History restores the history list.
        controller.model.section = .history
        try await fixture.wait("history restored") {
            !controller.verticalSplit.isSubviewCollapsed(controller.historyTop)
        }

        // Expanding history in Local Changes is remembered across section switches.
        controller.model.section = .changes
        try await fixture.wait("changes collapsed again") {
            controller.verticalSplit.isSubviewCollapsed(controller.historyTop)
        }
        controller.panes.sectionDividers.changesHistoryHeight = 180
        controller.positionHistorySplit()
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.verticalSplit.isSubviewCollapsed(controller.historyTop))
        #expect(controller.historyTop.frame.height >= RepositoryLayout.historyTopMinimum)
        controller.model.section = .history
        controller.model.section = .changes
        try await fixture.wait("changes remembered expanded history") {
            !controller.verticalSplit.isSubviewCollapsed(controller.historyTop)
                && controller.historyTop.frame.height >= RepositoryLayout.historyTopMinimum
        }

        // SectionPanes divider memory stores separate widths per section and clamps to each minimum.
        var memory = SectionPanes.DividerMemory()
        #expect(memory.changesHistoryHeight == 0)
        #expect(memory.filePaneWidth(for: .changes) == 260)
        #expect(memory.filePaneWidth(for: .history) == 240)
        memory.setFilePaneWidth(200, for: .changes)
        memory.setFilePaneWidth(200, for: .history)
        #expect(memory.filePaneWidth(for: .changes) == 260)
        #expect(memory.filePaneWidth(for: .history) == 200)
    }

    @Test func composerStartsCompactAndExpandsOnDescriptionFocusOrText() async throws {
        UITestSupport.bootstrap()
        let footer = CommitFooterView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 220), styleMask: [.titled], backing: .buffered,
            defer: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 220))
        window.contentView = host
        host.addSubview(footer)
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.layoutIfNeeded()

        let compactHeight = footer.frame.height
        #expect(!footer.isDescriptionExpanded)
        #expect(compactHeight > 60 && compactHeight < 86)

        footer.focusDescription()
        window.layoutIfNeeded()
        #expect(footer.isDescriptionExpanded)
        #expect(window.firstResponder === footer.bodyView)
        #expect(footer.frame.height >= 130)

        footer.collapseDescription()
        window.layoutIfNeeded()
        #expect(!footer.isDescriptionExpanded)
        #expect(abs(footer.frame.height - compactHeight) <= 1)

        footer.show(message: "Subject line\n\nBody details")
        window.layoutIfNeeded()
        #expect(footer.isDescriptionExpanded)
        #expect(footer.frame.height >= 130)

        footer.show(message: "")
        window.layoutIfNeeded()
        #expect(!footer.isDescriptionExpanded)
    }
}
