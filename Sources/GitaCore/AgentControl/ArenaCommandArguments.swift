import Foundation

public enum ArenaCommandArguments {
    private enum SyntaxError: LocalizedError {
        case incomplete
        var errorDescription: String? {
            String(localized: "Finish the quoted argument or escape in the check command.")
        }
    }

    public static func parse(_ command: String) throws -> [String] {
        var arguments: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let delimiter = quote {
                if character == delimiter { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if started { arguments.append(word) }
                word = ""
                started = false
                continue
            } else {
                word.append(character)
            }
            started = true
        }
        guard quote == nil, !escaped else { throw SyntaxError.incomplete }
        if started { arguments.append(word) }
        return arguments
    }
}
