import Foundation
import GitaCore
import Testing

@testable import GitaUI

struct SyntaxTokenizerTests {
    @Test func detectsAllSupportedLanguagesFromPaths() {
        #expect(SyntaxLanguage(path: "Sources/App.swift") == .swift)
        #expect(SyntaxLanguage(path: "Legacy.m") == .objectiveC)
        #expect(SyntaxLanguage(path: "Legacy.mm") == .objectiveC)
        #expect(SyntaxLanguage(path: "main.cpp") == .cFamily)
        #expect(SyntaxLanguage(path: "header.h") == .cFamily)
        #expect(SyntaxLanguage(path: "index.jsx") == .javascript)
        #expect(SyntaxLanguage(path: "types.tsx") == .typescript)
        #expect(SyntaxLanguage(path: "server.go") == .go)
        #expect(SyntaxLanguage(path: "lib.rs") == .rust)
        #expect(SyntaxLanguage(path: "Main.java") == .java)
        #expect(SyntaxLanguage(path: "App.kt") == .kotlin)
        #expect(SyntaxLanguage(path: "script.py") == .python)
        #expect(SyntaxLanguage(path: "run.zsh") == .shell)
        #expect(SyntaxLanguage(path: "config.json") == .json)
        #expect(SyntaxLanguage(path: "workflow.yml") == .yaml)
        #expect(SyntaxLanguage(path: "Cargo.toml") == .toml)
        #expect(SyntaxLanguage(path: "README.md") == .markdown)
        #expect(SyntaxLanguage(path: "Makefile") == .shell)
        #expect(SyntaxLanguage(path: "unknown.bin") == nil)
    }

    @Test func tokenizesKeywordsStringsCommentsNumbersAndTypes() {
        let swiftTokens = SyntaxTokenizer.tokenize(
            codeLines: [
                "/* multi-line",
                "   comment */",
                "struct User: Sendable {",
                "    let name = \"Ada\" // inline",
                "    let count = 42",
                "}",
            ],
            language: .swift)
        #expect(swiftTokens[0].first?.kind == .comment)
        #expect(swiftTokens[1].first?.kind == .comment)
        #expect(swiftTokens[2].contains { $0.kind == .keyword })
        #expect(swiftTokens[2].contains { $0.kind == .type })
        #expect(swiftTokens[3].contains { $0.kind == .string })
        #expect(swiftTokens[3].contains { $0.kind == .comment })
        #expect(swiftTokens[4].contains { $0.kind == .number })

        let jsonTokens = SyntaxTokenizer.tokenize(
            codeLines: ["{\"enabled\": true, \"count\": 3}"], language: .json)
        #expect(jsonTokens[0].contains { $0.kind == .property })
        #expect(jsonTokens[0].contains { $0.kind == .keyword })
        #expect(jsonTokens[0].contains { $0.kind == .number })

        let mdTokens = SyntaxTokenizer.tokenize(
            codeLines: ["# Heading", "Use `code` here"], language: .markdown)
        #expect(mdTokens[0].first?.kind == .heading)
        #expect(mdTokens[1].first?.kind == .string)

        let yamlTokens = SyntaxTokenizer.tokenize(codeLines: ["name: \"gita\" # app"], language: .yaml)
        #expect(yamlTokens[0].contains { $0.kind == .property })
        #expect(yamlTokens[0].contains { $0.kind == .string })
        #expect(yamlTokens[0].contains { $0.kind == .comment })

        let tomlTokens = SyntaxTokenizer.tokenize(codeLines: ["[package]", "version = \"1.0\""], language: .toml)
        #expect(tomlTokens[0].first?.kind == .heading)
        #expect(tomlTokens[1].contains { $0.kind == .property })
        #expect(tomlTokens[1].contains { $0.kind == .string })
    }

    @Test func keepsRemovedAndAddedLexerStatesIsolatedInDiff() {
        let lines = [
            DiffLine(text: "@@ -1,3 +1,3 @@", old: "", new: "", kind: "@", hunkIndex: 0),
            DiffLine(text: "-/* unclosed old comment", old: "1", new: "", kind: "-", hunkIndex: 0),
            DiffLine(text: "+let value = 10", old: "", new: "1", kind: "+", hunkIndex: 0),
        ]
        let tokens = SyntaxTokenizer.tokenize(lines: lines, path: "Demo.swift", isBlob: false)
        #expect(tokens[0].isEmpty)
        #expect(tokens[1].first?.kind == .comment)
        // Added line must NOT be treated as inside the removed line's block comment.
        #expect(tokens[2].contains { $0.kind == .keyword && $0.range == 1..<4 })
        #expect(tokens[2].contains { $0.kind == .number })
    }

    @Test func skipsOversizedLinesAndOversizedDocumentsAndMeets50kBudget() {
        let longLine = "let x = \"" + String(repeating: "a", count: 2_010) + "\""
        let longTokens = SyntaxTokenizer.tokenize(codeLines: [longLine, "let y = 1"], language: .swift)
        #expect(longTokens[0].isEmpty)
        #expect(!longTokens[1].isEmpty)

        let overLimit = Array(repeating: "let x = 1", count: SyntaxTokenizer.maxDocumentLines + 1)
        let skipped = SyntaxTokenizer.tokenize(codeLines: overLimit, language: .swift)
        #expect(skipped.count == overLimit.count)
        #expect(skipped.allSatisfy { $0.isEmpty })

        let fiftyK = (0..<50_000).map { "let line\($0) = \"value\" // comment" }
        let start = ContinuousClock.now
        let tokenized = SyntaxTokenizer.tokenize(codeLines: fiftyK, language: .swift)
        let elapsed = start.duration(to: .now)
        #expect(tokenized.count == 50_000)
        #expect(!tokenized[49_999].isEmpty)
        #expect(elapsed < .seconds(5))
    }

    @Test func diffDocumentBuilderPopulatesSyntaxTokensAndSplitRows() {
        let diff = [
            "diff --git a/App.swift b/App.swift",
            "index 1111111..2222222 100644",
            "--- a/App.swift",
            "+++ b/App.swift",
            "@@ -1,3 +1,3 @@",
            " let a = 1",
            "-let b = 2",
            "+let b = 3",
            " let c = 4",
            "",
        ].joined(separator: "\n")
        let result = DiffDocumentBuilder.build(diff, blob: false, path: "App.swift")
        #expect(result.syntaxTokens.count == result.document.lines.count)
        let plusRow = result.document.lines.firstIndex { $0.kind == "+" } ?? 0
        #expect(result.syntaxTokens[plusRow].contains { $0.kind == .keyword })
        #expect(result.splitRows.contains { $0.left?.text == "-let b = 2" && $0.right?.text == "+let b = 3" })
    }

    @MainActor
    @Test func tokenizesRemainingLanguagesTripleQuotesBackticksAndBlobState() {
        let python = SyntaxTokenizer.tokenize(
            codeLines: ["\"\"\"multi", "string\"\"\"", "@decorator", "def fn(x): # note"], language: .python)
        #expect(python[0].first?.kind == .string)
        #expect(python[1].first?.kind == .string)
        #expect(python[2].first?.kind == .keyword)
        #expect(python[3].contains { $0.kind == .keyword })
        #expect(python[3].contains { $0.kind == .comment })

        let js = SyntaxTokenizer.tokenize(
            codeLines: ["const msg = `hello", "world`", "export function run() { return 0x10 }"], language: .javascript)
        #expect(js[0].contains { $0.kind == .string })
        #expect(js[1].first?.kind == .string)
        #expect(js[2].contains { $0.kind == .number })

        let shell = SyntaxTokenizer.tokenize(codeLines: ["#!/bin/zsh", "export FOO=\"bar\" # env"], language: .shell)
        #expect(shell[0].first?.kind == .comment)
        #expect(shell[1].contains { $0.kind == .keyword })
        #expect(shell[1].contains { $0.kind == .string })
        #expect(shell[1].contains { $0.kind == .comment })

        let blobLines = [
            DiffLine(text: "/* start", old: "", new: "1", kind: " ", hunkIndex: nil),
            DiffLine(text: "end */ let k = 1", old: "", new: "2", kind: " ", hunkIndex: nil),
        ]
        let blobTokens = SyntaxTokenizer.tokenize(lines: blobLines, path: "Test.swift", isBlob: true)
        #expect(blobTokens[0].first?.kind == .comment)
        #expect(blobTokens[1].first?.kind == .comment)
        #expect(blobTokens[1].contains { $0.kind == .keyword })

        for kind in [
            SyntaxTokenKind.keyword, .string, .comment, .number, .type, .preprocessor, .heading, .property,
        ] {
            _ = kind.color
        }
    }
}
