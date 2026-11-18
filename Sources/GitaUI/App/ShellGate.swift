/// Whether the app can start something now. The shell builds one from its current state; every "can the user act
/// right now" question is a predicate here instead of a condition repeated at each call site.
struct ShellGate {
    var isLaunched = true
    var isLanguageRestarting = false
    var hasSetupGuide = false
    var hasMainWindow = false
    var hasAttachedSheet = false
    var hasReviewSheet = false
    /// A Git action runs in any tab.
    var isMutating = false
    var isLoading = false
    var hasSnapshot = false
    /// A notification's result waits to be shown, or is being verified.
    var hasPendingAttention = false
    var isAttentionInFlight = false
    var launchedInBackground = false
    /// The main window is on screen, not minimized or covered, and the app is active.
    var isWindowInFront = false
    var hasSeenSetupGuide = false

    /// Restart Now (Settings › General › Language): only from a quiet main window.
    var canRestartForLanguage: Bool {
        !isLanguageRestarting && !isMutating && !hasSetupGuide && !hasPendingAttention && !isAttentionInFlight
            && hasMainWindow && !hasAttachedSheet && !hasReviewSheet
    }

    /// A built-in terminal or an author tab in the main window: launched, with no setup guide over the window and no
    /// language restart closing it.
    var canOpenWindowContent: Bool { isLaunched && !isLanguageRestarting && !hasSetupGuide }

    var canPresentSetupGuide: Bool { !hasSetupGuide && hasMainWindow && !hasAttachedSheet && !isMutating }

    /// The Open at Login offer waits for a settled, interactive main window showing a repository.
    var canOfferLogin: Bool {
        !isLanguageRestarting && !launchedInBackground && isWindowInFront && !hasAttachedSheet && !hasSetupGuide
            && !hasPendingAttention && !isMutating && !isLoading && hasSnapshot && hasSeenSetupGuide
    }
}
