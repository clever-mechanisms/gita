import AppKit
import GitaCore

extension BisectStartSheet: CoordinatedSheet {}

/// Binds one `BisectPresenter` to the `GitService` instance it serves.
@MainActor
struct BisectAttachment {
    let serviceID: ObjectIdentifier
    let presenter: BisectPresenter
}

/// Visual `git bisect` banner, start sheet, palette actions, and Line History launcher.
extension RepositoryViewController {
    func syncBisectPresenter() {
        guard let service = model.service else {
            bisectAttachment?.presenter.cancelReads()
            bisectAttachment = nil
            bisectBanner.apply(BisectBannerModel(state: .inactive, action: .idle))
            bisectHeight.constant = 0
            return
        }
        let serviceID = ObjectIdentifier(service)
        if bisectAttachment?.serviceID != serviceID {
            bisectAttachment?.presenter.cancelReads()
            let gitDirectory = model.snapshot.flatMap { GitDirectoryLocator.locate(checkout: $0.root)?.gitDirectory }
            let presenter = BisectPresenter(service: service, gitDirectory: gitDirectory)
            bisectBanner.bind(to: presenter)
            presenter.onChange = { [weak self] next in
                self?.bisectBanner.apply(next)
                self?.bisectHeight.constant = next.isHidden ? 0 : BisectBannerView.height
            }
            presenter.onOpenCommit = { [weak self] sha in
                guard let self else { return }
                if self.model.section != .history { self.model.section = .history }
                self.selectCommit(id: sha)
            }
            presenter.onRepositoryMutated = { [weak self] in
                self?.model.refresh()
            }
            bisectAttachment = BisectAttachment(serviceID: serviceID, presenter: presenter)
            bisectBanner.apply(presenter.bannerModel)
            bisectHeight.constant = presenter.bannerModel.isHidden ? 0 : BisectBannerView.height
        }
        bisectAttachment?.presenter.refresh()
    }

    func detachBisect() {
        bisectAttachment?.presenter.cancelReads()
        bisectAttachment = nil
    }

    func presentBisectStartSheet(initialBad: String? = nil) {
        guard let window = view.window, let service = model.service, !model.isMutating else { return }
        syncBisectPresenter()
        guard let presenter = bisectAttachment?.presenter else { return }
        let bad = initialBad ?? model.selectedCommit?.id ?? "HEAD"
        let sheet = BisectStartSheet(
            recentCommits: model.snapshot?.commits ?? [],
            initialBad: bad,
            initialGood: ""
        ) { badRef, goodRef in
            try await presenter.start(bad: badRef, good: goodRef)
        }
        sheets.present(ReviewSheetHandle(sheet), service: service, on: window)
    }

    func openLineHistory(range: LineRangeSpec) {
        let revision =
            range.revision ?? (model.section != .changes ? model.selectedCommit?.id : nil)
        let resolved = LineRangeSpec(
            path: range.path, startLine: range.startLine, endLine: range.endLine, revision: revision)
        commands?.openLineHistory(range: resolved)
    }

    func bisectPaletteActions() -> [(item: NSMenuItem, keywords: [String])] {
        guard let presenter = bisectAttachment?.presenter, presenter.state != .inactive else { return [] }
        return Self.makeBisectPaletteItems(presenter: presenter)
    }

    private static func makeBisectPaletteItems(presenter: BisectPresenter) -> [(item: NSMenuItem, keywords: [String])] {
        let canAct = presenter.bannerModel.canAct
        let canStep = canAct && presenter.bannerModel.showsStepActions
        return [
            bisectPaletteItem(
                String(localized: "Bisect: Mark Good"), symbol: "checkmark.circle.fill", enabled: canStep,
                keywords: ["bisect", "good"], handler: { [weak presenter] in presenter?.markGood() }),
            bisectPaletteItem(
                String(localized: "Bisect: Mark Bad"), symbol: "xmark.circle.fill", enabled: canStep,
                keywords: ["bisect", "bad"], handler: { [weak presenter] in presenter?.markBad() }),
            bisectPaletteItem(
                String(localized: "Bisect: Skip"), symbol: "forward.end", enabled: canStep,
                keywords: ["bisect", "skip"], handler: { [weak presenter] in presenter?.skip() }),
            bisectPaletteItem(
                String(localized: "Bisect: Reset"), symbol: "arrow.uturn.backward", enabled: canAct,
                keywords: ["bisect", "reset", "abort", "finish"], handler: { [weak presenter] in presenter?.reset() }),
        ]
    }

    private static func bisectPaletteItem(
        _ title: String, symbol: String, enabled: Bool, keywords: [String], handler: @escaping @MainActor () -> Void
    ) -> (item: NSMenuItem, keywords: [String]) {
        let item = MenuAction(title, symbol: symbol, handler: handler)
        item.isEnabled = enabled
        return (item, keywords)
    }
}
