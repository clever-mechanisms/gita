/// The feed's symbol and colour for each kind of event.
extension AttentionKind {
    var panelSymbol: (name: String, color: PanelColor) {
        switch self {
        case .pullRequestOpened: ("arrow.triangle.pull", .accentText)
        case .reviewRequested: ("eye.fill", .needsInputText)
        case .pullRequestMerged: ("arrow.triangle.merge", .merged)
        case .checksFailed: ("xmark.circle.fill", .failure)
        case .checksFixed: ("checkmark.circle.fill", .success)
        case .previewReady: ("globe", .accentText)
        case .productionDeployed: ("bolt.fill", .success)
        case .agentNeedsInput: ("bubble.left.fill", .needsInputText)
        case .agentFinished: ("checkmark.seal.fill", .success)
        }
    }
}
