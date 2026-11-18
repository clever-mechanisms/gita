import AppKit
import GitaCore

/// Settings ▸ AI Agents ▸ AI Review: the agent and the skill that review branches and commits, with a link to the
/// skill's source.
extension AgentsSettingsPane {
    func configureReview() {
        reviewAgent.onChange = { [weak self] popup in self?.store(popup.selectedValue, as: .reviewAgent) }
        reviewAgent.setAccessibilityIdentifier("settings.reviewAgent")
        reviewAgent.toolTip = String(
            localized: "Reviews branches and commits from their menus, in the terminal chosen in General")
        // Each skill under its brand name, Gitā's own last; the link opens the selected skill's source.
        for skill in ReviewSkill.allCases {
            if skill == .builtIn { reviewSkill.menu?.addItem(.separator()) }
            reviewSkill.addItem(skill.displayName, value: skill.rawValue)
            reviewSkill.lastItem?.toolTip = skill.sourceURL?.absoluteString
        }
        reviewSkill.onChange = { [weak self] popup in self?.store(popup.selectedValue, as: .reviewSkill) }
        reviewSkill.setAccessibilityIdentifier("settings.reviewSkill")
        reviewSkillLink.setAccessibilityIdentifier("settings.reviewSkillSource")
    }

    func reviewGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "AI Review"),
            [
                SettingsRow(
                    String(localized: "Agent"), [reviewAgent],
                    help: String(
                        localized:
                            """
                            “Review with …” in a branch's or commit's menu opens this agent in a terminal to \
                            review it. Only agent CLIs installed on this Mac are listed.
                            """
                    )),
                SettingsRow(
                    String(localized: "Review"), [reviewSkillLink, reviewSkill],
                    help: String(
                        localized:
                            """
                            The skill the agent follows: a published review skill or Gitā's own, each bundled \
                            with Gitā. Read Skill opens its source.
                            """
                    )),
            ])
    }

    var selectedSkill: ReviewSkill { ReviewSkill(rawValue: Preference.reviewSkill.string(defaults)) ?? .default }

    func refreshReview() {
        fillReviewAgents(ReviewLauncher.installedAgents)
        let skill = selectedSkill
        if !reviewSkill.select(value: skill.rawValue) { reviewSkill.selectItem(at: 0) }
        reviewSkillLink.isHidden = skill.sourceURL == nil
        reviewSkillLink.toolTip = skill.sourceURL?.absoluteString
    }

    /// The installed agent CLIs with their marks; "None installed" when there's none (Review items are then hidden).
    func fillReviewAgents(_ agents: [ReviewAgent]) {
        let signature = agents.map(\.rawValue).joined(separator: ",")
        if reviewAgent.contentSignature != signature {
            reviewAgent.removeAllItems()
            for agent in agents {
                reviewAgent.addItem(agent.displayName, value: agent.rawValue)
                reviewAgent.lastItem?.image = ReviewLauncher.image(agent)
            }
            if agents.isEmpty { reviewAgent.addItem(withTitle: String(localized: "None installed")) }
            reviewAgent.contentSignature = signature
        }
        reviewAgent.isEnabled = !agents.isEmpty
        // The saved agent while it is installed, else the first installed (`agents` is in preference order).
        let saved = ReviewAgent(rawValue: Preference.reviewAgent.string(defaults)).flatMap {
            agents.contains($0) ? $0 : nil
        }
        if let agent = saved ?? agents.first { reviewAgent.select(value: agent.rawValue) }
    }
    private func store(_ value: String?, as preference: Preference) {
        guard let value else { return }
        preference.set(value, defaults)
        refresh()
    }
    func openReviewSkill() {
        if let url = selectedSkill.sourceURL, let safe = Deck.safeWebURL(url) { environment.system.openURL(safe) }
    }
}
