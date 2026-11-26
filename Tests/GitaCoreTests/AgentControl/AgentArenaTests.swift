import Foundation
import Testing

@testable import GitaCore

@Suite struct AgentControlAgentArenaTests {
    @Test func checkArgumentsPreserveQuotingAndEscapes() throws {
        let command = #"tool 'two words' "say \"hi\"" escaped\ space a''b "" 'x\y' ; *.swift"#
        #expect(
            try ArenaCommandArguments.parse(command) == [
                "tool", "two words", "say \"hi\"", "escaped space", "ab", "", #"x\y"#, ";", "*.swift",
            ])
        #expect(try ArenaCommandArguments.parse("  ").isEmpty)
        for invalid in ["'unfinished", "\"unfinished", "trailing\\"] {
            #expect(throws: (any Error).self) { try ArenaCommandArguments.parse(invalid) }
        }
    }

    @Test func presetsResolvePromptsAsSingleArguments() {
        let prompt = "Fix spaces; $(literal)\nand quotes'"
        let expected = [
            ["-p", prompt], ["exec", prompt], ["-p", prompt], ["run", prompt], ["--message", prompt, "--yes"],
        ]
        #expect(ArenaAgentConfig.defaultPresets.map { $0.resolvedArguments(prompt: prompt) } == expected)
        let config = ArenaAgentConfig(
            id: "custom", displayName: "Custom", tool: .codex,
            executable: "/usr/bin/touch", arguments: [])
        #expect(config.resolvedArguments(prompt: prompt) == [prompt])
        #expect(config.resolvedArguments(prompt: "before\0after").isEmpty)
    }

    @Test func compareDirtyWorktreesAndPickWinner() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("base", "initial")
            try await repo.commit()
            let base = try await repo.git(["rev-parse", "HEAD"])
            let arena = AgentArenaService()
            let (alpha, beta) = try await arena.createWorktrees(in: repo.root, baseCommit: base, runID: "race")
            do {
                let prompt = "file with spaces; $(literal)"
                let config = ArenaAgentConfig(
                    id: "touch", displayName: "Touch", tool: .codex,
                    executable: "/usr/bin/touch", arguments: ["{prompt}"])
                try repo.write("shared", "alpha\n", in: alpha.worktreePath)
                try repo.write("shared", "beta\n", in: beta.worktreePath)
                let check = ["/bin/test", "-f", prompt]
                async let a = arena.runContestant(
                    alpha, config: config, prompt: prompt, baseCommit: base, checkCommand: check)
                async let b = arena.runContestant(
                    beta, config: config, prompt: prompt, baseCommit: base, checkCommand: check)
                let (one, two) = try await (a, b)
                #expect(one.agentExitCode == 0)
                #expect(one.checkResult?.succeeded == true)
                #expect(two.checkResult?.succeeded == true)
                #expect(one.changedFiles == [prompt, "shared"])
                #expect(two.diffFromBase.contains("+beta"))
                let comparison = try await arena.compare(
                    in: repo.root, runID: "race", prompt: prompt,
                    baseCommit: base, alpha: one, beta: two)
                #expect(comparison.alphaVsBetaDiff.contains("-alpha\n+beta"))
                #expect(!comparison.isDiffTruncated)
                let kept = try await arena.pickWinner(.beta, in: repo.root, comparison: comparison)
                #expect(kept.keptWorktree == beta.worktreePath)
                #expect(kept.keptBranch == beta.branchName)
                #expect(!FileManager.default.fileExists(atPath: alpha.worktreePath.path))
                #expect(try repo.read("shared", in: kept.keptWorktree) == "beta\n")
                #expect(try await repo.git(["branch", "--list", alpha.branchName]).isEmpty)
                #expect(try await repo.git(["rev-parse", "HEAD"]) == base)
            } catch {
                await arena.cleanup(in: repo.root, workspaces: [alpha, beta])
                throw error
            }
            await arena.cleanup(in: repo.root, workspaces: [beta])
        }
    }

    @Test func failureRollsBackOnlyOwnedBranchesAndCancelledDiscardCompletes() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("base", "initial")
            try await repo.commit()
            let arena = AgentArenaService()
            let (a, b) = try await arena.createWorktrees(in: repo.root, baseCommit: "HEAD", runID: "discard")
            await #expect(throws: (any Error).self) {
                _ = try await arena.createWorktrees(in: repo.root, baseCommit: "HEAD", runID: "discard")
            }
            #expect(FileManager.default.fileExists(atPath: a.worktreePath.path))
            #expect(FileManager.default.fileExists(atPath: b.worktreePath.path))
            await arena.cleanup(in: repo.root, workspaces: [a])
            // This attempt creates alpha successfully before the existing beta branch blocks it.
            await #expect(throws: (any Error).self) {
                _ = try await arena.createWorktrees(in: repo.root, baseCommit: "HEAD", runID: "discard")
            }
            #expect(try await repo.git(["branch", "--list", a.branchName]).isEmpty)
            #expect(FileManager.default.fileExists(atPath: b.worktreePath.path))
            let cleanup = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await arena.cleanup(in: repo.root, workspaces: [a, b])
            }
            await cleanup.value
            #expect(!FileManager.default.fileExists(atPath: a.worktreePath.deletingLastPathComponent().path))
            #expect(try await repo.git(["branch", "--list", "gita/arena-*"]).isEmpty)
            #expect(
                try await repo.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
        }
    }
}
