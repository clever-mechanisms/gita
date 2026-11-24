/// Non-modal informational notices and recoverable failures.
extension AppModel {
    func showBanner(_ banner: ContentBanner) {
        contentBanner = banner
    }

    func showNonDestructiveError(
        _ title: String, _ message: String, retry: ContentBanner.RetryAction? = nil
    ) {
        showBanner(.failure(title: title, message: message, retry: retry))
    }

    func dismissBanner() {
        contentBanner = .none
    }

    func retryBanner() {
        guard let retry = contentBanner.retryAction else { return }
        contentBanner = .none
        retry.perform()
    }
}
