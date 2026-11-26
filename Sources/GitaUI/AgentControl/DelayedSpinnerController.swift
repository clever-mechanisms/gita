import AppKit

@MainActor
final class DelayedSpinnerController {
    let indicator = NSProgressIndicator()
    private var task: Task<Void, Never>?

    init() {
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.usesThreadedAnimation = false
        indicator.isDisplayedWhenStopped = Deck.reduceMotion
        indicator.setAccessibilityLabel(String(localized: "Loading"))
        indicator.isHidden = true
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.indicator.isHidden = false
            if !Deck.reduceMotion { self?.indicator.startAnimation(nil) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        indicator.stopAnimation(nil)
        indicator.isHidden = true
    }

    deinit { task?.cancel() }
}
