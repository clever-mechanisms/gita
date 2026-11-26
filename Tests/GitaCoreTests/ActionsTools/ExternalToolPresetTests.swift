import Foundation
import Testing

@testable import GitaCore

@Suite struct ExternalToolPresetTests {
    @Test func installationMetadata() {
        typealias Installation = (name: String, identifiers: [String], bundled: String, standalone: [String])
        func standalone(_ executable: String) -> [String] {
            ["/opt/homebrew/bin/" + executable, "/usr/local/bin/" + executable]
        }
        let installations: [ExternalToolPreset: Installation] = [
            .kaleidoscope: (
                String(localized: "Kaleidoscope"),
                [
                    "app.kaleidoscope.v6", "app.kaleidoscope.v5", "app.kaleidoscope.v4",
                    "app.kaleidoscope.v3", "com.blackpixel.kaleidoscope",
                ], "Kaleidoscope.app/Contents/MacOS/ksdiff", standalone("ksdiff")
            ),
            .beyondCompare: (
                String(localized: "Beyond Compare"), ["com.ScooterSoftware.BeyondCompare"],
                "Beyond Compare.app/Contents/MacOS/bcomp", standalone("bcomp")
            ),
            .vsCode: (
                String(localized: "Visual Studio Code"), ["com.microsoft.VSCode"],
                "Visual Studio Code.app/Contents/Resources/app/bin/code", standalone("code")
            ),
            .cursor: (
                String(localized: "Cursor"), ["com.todesktop.230313mzl4w4u92"],
                "Cursor.app/Contents/Resources/app/bin/cursor", standalone("cursor")
            ),
            .fileMerge: (
                String(localized: "FileMerge"), ["com.apple.dt.Xcode"],
                "Xcode.app/Contents/Developer/usr/bin/opendiff", ["/usr/bin/opendiff"]
            ),
            .diffMerge: (
                String(localized: "DiffMerge"), ["com.sourcegear.DiffMerge"],
                "DiffMerge.app/Contents/MacOS/DiffMerge", standalone("diffmerge")
            ),
            .araxisMerge: (
                String(localized: "Araxis Merge"), ["com.araxis.merge"], "Araxis Merge.app/Contents/Utilities/compare",
                []
            ),
            .p4Merge: (
                String(localized: "P4Merge"), ["com.perforce.p4merge"], "p4merge.app/Contents/MacOS/p4merge",
                standalone("p4merge")
            ),
            .custom: (String(localized: "Custom"), [], "", []),
        ]
        #expect(Set(installations.keys) == Set(ExternalToolPreset.allCases))
        for (preset, installation) in installations {
            let embedded = installation.bundled.split(separator: "/", maxSplits: 1).dropFirst().joined()
            let bundled = installation.bundled.isEmpty ? [] : ["/Applications/" + installation.bundled]
            let paths = preset == .fileMerge ? installation.standalone + bundled : bundled + installation.standalone
            #expect(preset.displayName == installation.name)
            #expect(preset.bundleIdentifiers == installation.identifiers)
            #expect(preset.embeddedCLI == embedded)
            #expect(preset.cliPaths == paths)
        }
    }

    @Test func argumentOrderAndFlags() {
        let pair = ["$LEFT", "$RIGHT"]
        let codeDiff = ["--wait", "--diff"] + pair
        let codeMerge = ["--wait", "--merge", "$RIGHT", "$LEFT", "$BASE", "$MERGED"]
        let arguments: [ExternalToolPreset: (diff: [String], merge: [String])] = [
            .kaleidoscope: (["--wait"] + pair, ["--merge", "--wait", "--output", "$MERGED", "--base", "$BASE"] + pair),
            .beyondCompare: (pair, pair + ["$BASE", "-mergeoutput=$MERGED"]),
            .vsCode: (codeDiff, codeMerge),
            .cursor: (codeDiff, codeMerge),
            .fileMerge: (pair, pair + ["-ancestor", "$BASE", "-merge", "$MERGED"]),
            .diffMerge: (pair, ["--merge", "--result=$MERGED", "$LEFT", "$BASE", "$RIGHT"]),
            .araxisMerge: (["-wait", "-2"] + pair, ["-wait", "-merge", "-3", "-a1", "$BASE"] + pair + ["$MERGED"]),
            .p4Merge: (pair, ["$BASE", "$RIGHT", "$LEFT", "$MERGED"]),
            .custom: (pair, ["$BASE"] + pair + ["$MERGED"]),
        ]
        #expect(Set(arguments.keys) == Set(ExternalToolPreset.allCases))
        for (preset, expected) in arguments {
            #expect(preset.defaultDiffArguments == expected.diff)
            #expect(preset.defaultMergeArguments == expected.merge)
        }
    }

    @Test func toolErrorDescriptions() {
        let name = "DiffMerge"
        let key = "$BASE"
        let code: Int32 = 17
        let detail = "Input file missing"
        let messages: [(ExternalToolError, String)] = [
            (.unavailable(name), String(localized: "\(name) is not installed.")),
            (.missingPath(key), String(localized: "No file is available for \(key).")),
            (.temporaryDirectory, String(localized: "Could not prepare temporary comparison files.")),
            (
                .invalidOutput,
                String(localized: "Choose a regular local file inside this worktree for the merge result.")
            ),
            (.exited(code, detail), String(localized: "The tool exited with status \(code). \(detail)")),
        ]
        for (error, message) in messages {
            #expect(error.errorDescription == message)
        }
    }
}
