import Foundation
import GitaCore

/// What the terminal page tells the app (`Resources/Terminal/terminal.js`): it is ready at a size, the user typed
/// something, the terminal was resized, or the program set a title.
enum TerminalMessage: Equatable {
    case ready(PseudoTerminal.Size)
    case input(Data)
    case resize(PseudoTerminal.Size)
    case title(String)

    /// A message body as WebKit hands it over; nil for anything else.
    init?(_ body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "ready", "resize":
            guard let columns = body["cols"] as? Int, let rows = body["rows"] as? Int else { return nil }
            let size = PseudoTerminal.Size(columns: columns, rows: rows)
            self = type == "ready" ? .ready(size) : .resize(size)
        case "input":
            guard let text = body["data"] as? String else { return nil }
            self = .input(Data(text.utf8))
        case "binary":
            // Mouse reports: one character per byte.
            guard let text = body["data"] as? String else { return nil }
            self = .input(Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
        case "title":
            guard let title = body["title"] as? String else { return nil }
            self = .title(title)
        default:
            return nil
        }
    }
}
