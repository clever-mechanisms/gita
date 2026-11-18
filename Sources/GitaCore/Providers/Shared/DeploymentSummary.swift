import Foundation

public struct DeploymentSummary: Sendable, Hashable {
    public enum Environment: Sendable, Hashable {
        case production, preview
        case custom(String)
        case unknown

        /// Display name only; grouping uses the enum and preserves custom slugs.
        public var name: String? {
            switch self {
            case .production: String(localized: "Production")
            case .preview: String(localized: "Preview")
            case .custom(let name): name
            case .unknown: nil
            }
        }
    }

    public var environment: Environment

    public init(environment: Environment) { self.environment = environment }
}
