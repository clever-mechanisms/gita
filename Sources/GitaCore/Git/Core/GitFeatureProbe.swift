/// A Git capability probed once per service: unknown until the first probe answers.
enum GitFeatureProbe: Sendable, Equatable {
    case unknown
    case known(Bool)
}
