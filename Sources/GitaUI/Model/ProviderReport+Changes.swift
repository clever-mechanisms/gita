import GitaCore

extension ProviderReport {
    /// Whether anything shown differs from `previous` (a missing previous report always differs).
    func differs(from previous: ProviderReport?) -> Bool {
        guard let previous else { return true }
        return previous.items != items || previous.statusDiffers(from: self) || previous.sourceID != sourceID
            || previous.vercel != vercel || previous.vercelSignals != vercelSignals
    }

    /// The connection status or its explanation changed.
    func statusDiffers(from other: ProviderReport?) -> Bool {
        other?.status != status || other?.diagnostic != diagnostic
    }
}

extension ProviderKind {
    /// The provider's product name, as Activity titles its events.
    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .vercel: "Vercel"
        case .orca: "Orca"
        }
    }
}
