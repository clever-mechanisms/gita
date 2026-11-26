import Foundation

enum DiffLineContent {
    private static let punctuation = CharacterSet.punctuationCharacters.union(.symbols)

    // Preserve quoted text and token boundaries. In particular a formatting pass must never
    // hide a change from "a  b" to "a b" inside a string literal.
    static func normalize(_ text: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        var space = false
        for char in text {
            if let delimiter = quote {
                result.append(char)
                if !escaped && char == delimiter { quote = nil }
                escaped = !escaped && char == "\\"
            } else if char.isWhitespace {
                space = !result.isEmpty
            } else {
                if space, let last = result.last, needsSeparator(last, char) { result.append(" ") }
                space = false
                result.append(char)
                if ["'", "\"", "`"].contains(char) { quote = char }
            }
        }
        return result
    }

    private static func needsSeparator(_ left: Character, _ right: Character) -> Bool {
        // Ignore spacing around punctuation, but preserve distinct identifiers and operators.
        let lhs = left.unicodeScalars.allSatisfy(punctuation.contains) && left != "_"
        let rhs = right.unicodeScalars.allSatisfy(punctuation.contains) && right != "_"
        return lhs == rhs
    }
}
