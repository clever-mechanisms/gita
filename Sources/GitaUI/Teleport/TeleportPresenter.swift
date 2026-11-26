import AppKit
import GitaCore

enum TeleportState: Equatable, Sendable {
    case idle
    case resolving(ParsedTeleportInput)
    case resolved(TeleportDestination)
    case ambiguous(ParsedTeleportInput, [TeleportDestination])
    case notFound(String)
    case failed(String)
}

@MainActor
final class TeleportPresenter {
    private(set) var state: TeleportState = .idle {
        didSet {
            for banner in banners.allObjects { banner.display(state) }
            switch state {
            case .resolved(let destination):
                TeleportControls.announce(TeleportBannerView.presentation(destination.target).0)
            case .ambiguous: TeleportControls.announce(String(localized: "Choose a destination"))
            case .notFound(let message), .failed(let message): TeleportControls.announce(message)
            default: break
            }
        }
    }
    var onTeleport: ((TeleportDestination) -> Void)?
    private let resolver: TeleportResolver
    private let banners = NSHashTable<TeleportBannerView>.weakObjects()
    private var task: Task<Void, Never>?

    init(resolver: TeleportResolver = .init()) { self.resolver = resolver }
    deinit { task?.cancel() }

    func attach(_ view: TeleportBannerView) {
        banners.add(view)
        view.display(state)
    }

    func inspect(_ input: String, repositories: [TeleportRepositoryEntry]) {
        guard let parsed = TeleportParser.parse(input) else {
            dismiss()
            return
        }
        inspect(parsed, repositories: repositories)
    }

    func inspect(_ parsed: ParsedTeleportInput, repositories: [TeleportRepositoryEntry]) {
        task?.cancel()
        task = Task { [weak self, resolver] in
            do {
                let result = try await resolver.resolve(parsed, in: repositories)
                try Task.checkCancellation()
                switch result {
                case .resolved(let destination): self?.state = .resolved(destination)
                case .ambiguous(let options): self?.state = .ambiguous(parsed, options)
                case .notFound: self?.state = .notFound(String(localized: "No matching repository found."))
                }
            } catch {
                if !Task.isCancelled { self?.state = .failed(error.localizedDescription) }
            }
        }
        state = .resolving(parsed)
    }

    func selectAmbiguous(at index: Int) {
        guard case .ambiguous(_, let options) = state, options.indices.contains(index) else { return }
        state = .resolved(options[index])
    }

    func confirmTeleport() {
        guard case .resolved(let destination) = state else { return }
        dismiss()
        onTeleport?(destination)
    }

    func dismiss() {
        task?.cancel()
        task = nil
        state = .idle
    }
}
