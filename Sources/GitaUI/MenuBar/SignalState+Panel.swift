import GitaCore

/// How the panel names a repository's checks: one symbol and one word per outcome.
extension SignalState {
    var panelSymbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .running, .pending: "circle.dotted.circle"
        case .cancelled, .neutral: "minus.circle"
        }
    }

    var panelStateText: String {
        switch self {
        case .success: String(localized: "passing")
        case .failure: String(localized: "failing")
        case .running, .pending: String(localized: "running")
        case .cancelled, .neutral: String(localized: "unknown")
        }
    }
}
