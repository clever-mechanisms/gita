import AppKit

/// Draws author avatars for the drawn history and commit views. A seam over `Deck.drawAvatar`, which reads the
/// avatar cache and assigns author colours: tests replace it so rendering stays free of those side effects.
@MainActor
enum AvatarPainter {
    typealias Paint = @MainActor (_ name: String, _ email: String, _ rect: NSRect, _ lane: Int?) -> Void
    static var paint: Paint = { name, email, rect, lane in Deck.drawAvatar(name, email: email, in: rect, lane: lane) }

    static func draw(_ name: String, email: String, in rect: NSRect, lane: Int? = nil) {
        paint(name, email, rect, lane)
    }
}
