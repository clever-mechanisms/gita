import AppKit
import GitaCore

extension BisectStartSheet: CoordinatedSheet {}

/// Visual `git bisect` banner, start sheet, palette actions, and Line History launcher.
extension RepositoryViewController {
    func syncBisectPresenter() {
        guard let service = model.service else {
            bisectPresenter?.cancelReads()
            bisectPresenter = nil
            bisectServiceID = nil
            bisectBanner.apply(BisectBannerModel(state: .inactive, action: .idle))
            bisectHeight.constant = 0
            return
        }
        let serviceID = ObjectIdentifier(service)
        if bisectServiceID != serviceID || bisectPresenter == nil {
            bisectPresenter?.cancelReads()
            let presenter = BisectPresenter(service: service)
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
            bisectPresenter = presenter
            bisectServiceID = serviceID
            bisectBanner.apply(presenter.bannerModel)
            bisectHeight.constant = presenter.bannerModel.isHidden ? 0 : BisectBannerView.height
        }
        bisectPresenter?.refresh()
    }

    func detachBisect() {
        bisectPresenter?.cancelReads()
        bisectPresenter = nil
        bisectServiceID = nil
    }

    func presentBisectStartSheet(initialBad: String? = nil) {
        guard let window = view.window, let service = model.service, !model.isMutating else { return }
        syncBisectPresenter()
        guard let presenter = bisectPresenter else { return }
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
        guard let presenter = bisectPresenter else { return [] }
        switch presenter.state {
        case .inactive:
            return []
        case .active, .finished:
            let canAct = presenter.bannerModel.canAct
            let good = MenuAction(String(localized: "Bisect: Mark Good"), symbol: "checkmark.circle.fill") {
                [weak presenter] in presenter?.markGood()
            }
            good.isEnabled = canAct && presenter.bannerModel.showsStepActions
            let bad = MenuAction(String(localized: "Bisect: Mark Bad"), symbol: "xmark.circle.fill") {
                [weak presenter] in presenter?.markBad()
            }
            bad.isEnabled = canAct && presenter.bannerModel.showsStepActions
            let skip = MenuAction(String(localized: "Bisect: Skip"), symbol: "forward.end") { [weak presenter] in
                presenter?.skip()
            }
            skip.isEnabled = canAct && presenter.bannerModel.showsStepActions
            let reset = MenuAction(String(localized: "Bisect: Reset"), symbol: "arrow.uturn.backward") {
                [weak presenter] in presenter?.reset()
            }
            reset.isEnabled = canAct
            return [
                (good, ["bisect", "good"]),
                (bad, ["bisect", "bad"]),
                (skip, ["bisect", "skip"]),
                (reset, ["bisect", "reset", "abort", "finish"]),
            ]
        }
    }
}
