import Foundation
import GitaCore
import Testing

struct StructuredDiffFormatterTests {
    private func entries(_ old: String, _ new: String, _ path: String) -> [StructuredDiffEntry] {
        guard case .parsed(_, let entries, false) = StructuredDiffFormatter.diff(oldText: old, newText: new, path: path)
        else {
            Issue.record("Expected a complete structured result")
            return []
        }
        return entries
    }

    @Test func nestedJSONAndCollidingKeys() {
        let before = #"{"a":{"b":[{"c":1}]},"a.b":true,"gone":0}"#
        let after = #"{"a":{"b":[{"c":"1"}]},"a.b":false,"new":[]}"#
        let changes = entries(before, after, "project.json")
        #expect(changes.count == 4)
        #expect(changes.contains { $0.keyPath == "a.b[0].c" && $0.kind == .modified })
        #expect(changes.contains { $0.oldValue == "true" && $0.newValue == "false" })
        #expect(changes.contains { $0.keyPath == "new" && $0.kind == .added })
        #expect(changes.contains { $0.keyPath == "gone" && $0.kind == .removed })
    }

    @Test func emptyContainersAndLineEndings() {
        #expect(entries("{}", #"{"x":1}"#, "file.json").map(\.keyPath) == ["x"])
        let old = "# One\r\nA\r\n## Two\r\nB"
        #expect(entries(old, old + "!", "file.md").map(\.keyPath) == ["# One > ## Two"])
    }

    @Test func catalogValues() throws {
        let old =
            #"{"strings":{"Save":{"localizations":{"fr":{"stringUnit":{"state":"translated","value":"Avant"}}}}}}"#
        let change = try #require(
            entries(
                old, old.replacingOccurrences(of: "Avant", with: "Après"),
                "Localizable.xcstrings"
            ).first)
        #expect(change.keyPath == "\"Save\" [fr].value" && change.section == "Save")
        #expect(change.oldValue == "Avant" && change.newValue == "Après")
    }

    @Test func propertyLists() throws {
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            let old = try PropertyListSerialization.data(fromPropertyList: ["Launch": true], format: format, options: 0)
            let new = try PropertyListSerialization.data(
                fromPropertyList: ["Launch": false], format: format, options: 0)
            guard
                case .parsed(.plist, let changes, false) = StructuredDiffFormatter.diff(
                    oldData: old, newData: new,
                    path: "Info.plist")
            else {
                Issue.record("Expected plist entries")
                return
            }
            #expect(changes.map(\.keyPath) == ["Launch"])
        }
        #expect(entries("{ foo = before; }", "{ foo = after; }", "file.plist").first?.newValue == "after")
    }

    @Test func elementAttributes() {
        let old = #"<svg viewBox="0 0 16 16"><g id="header"><path d="M0 0" fill="red"/></g></svg>"#
        let new = old.replacingOccurrences(of: "red", with: "blue").replacingOccurrences(of: "M0", with: "M1")
        let changes = entries(old, new, "icon.svg")
        #expect(changes.map(\.keyPath) == ["svg/g#header/path[0]@d", "svg/g#header/path[0]@fill"])
    }

    @Test func headingsAndFences() {
        let old = "# Intro\nStart\n## Setup\n~~~\n# Code\n~~~\nEnd"
        let new = old.replacingOccurrences(of: "End", with: "Finish") + "\n## Next\nGo"
        let changes = entries(old, new, "readme.md")
        #expect(changes.map(\.keyPath) == ["# Intro > ## Setup", "# Intro > ## Next"])
        #expect(changes.map(\.kind) == [.modified, .added])
    }

    @Test func budgetsAndFallback() {
        let capped = StructuredDiffFormatter.diff(
            oldText: "{}", newText: #"{"a":1,"b":2}"#, path: "a.json",
            maxEntries: 1)
        if case .parsed(_, let changes, true) = capped {
            #expect(changes.count == 1)
        } else {
            Issue.record("Expected bounded output")
        }
        for (path, text) in [("a.svg", "<svg>"), ("a.json", "{"), ("a.xcstrings", "[]"), ("a.plist", "{broken")] {
            if case .fallback = StructuredDiffFormatter.diff(oldText: "", newText: text, path: path) { continue }
            Issue.record("Expected fallback for \(path)")
        }
        let big = StructuredDiffFormatter.diff(oldText: "{}", newText: "{}", path: "a.json", maxInputBytes: 1)
        if case .fallback = big {} else { Issue.record("Expected size fallback") }
        #expect(StructuredDiffFormatter.diff(oldText: "", newText: "", path: "main.swift") == .unsupported)
    }
}
