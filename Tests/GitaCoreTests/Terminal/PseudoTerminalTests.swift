import Foundation
import Testing

@testable import GitaCore

/// What a program on a `PseudoTerminal` printed and how it ended, collected from the terminal's queue.
private final class TerminalTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var code: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }

    func append(_ data: Data) { lock.withLock { bytes.append(data) } }

    func exited(_ code: Int32) {
        let waiting = lock.withLock {
            self.code = code
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume(returning: code) }
    }

    /// The exit code, once the program has exited.
    func exitCode() async -> Int32 {
        await withCheckedContinuation { continuation in
            let known = lock.withLock {
                if code == nil { waiters.append(continuation) }
                return code
            }
            if let known { continuation.resume(returning: known) }
        }
    }

    /// Waits up to five seconds for `text` to contain `fragment`.
    func waitFor(_ fragment: String) async -> Bool {
        for _ in 0..<500 {
            if text.contains(fragment) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite("Pseudo-terminal")
struct PseudoTerminalTests {
    private static let folder = FileManager.default.temporaryDirectory

    private func run(
        _ script: String, size: PseudoTerminal.Size = .init(columns: 80, rows: 24)
    ) throws -> (
        PseudoTerminal, TerminalTranscript
    ) {
        let transcript = TerminalTranscript()
        let command = PseudoTerminal.Command(
            executable: "/bin/sh", arguments: ["sh", "-c", script], environment: ["PATH": "/usr/bin:/bin"],
            directory: Self.folder)
        let terminal = try PseudoTerminal(
            command, size: size, output: { transcript.append($0) }, exit: { transcript.exited($0) })
        return (terminal, transcript)
    }

    @Test func theProgramRunsOnATerminalOfTheGivenSizeInTheFolder() async throws {
        let (_, transcript) = try run("tty; stty size; pwd -P; exit 3", size: .init(columns: 101, rows: 31))
        #expect(await transcript.exitCode() == 3)
        #expect(transcript.text.contains("/dev/ttys"))
        #expect(transcript.text.contains("31 101"))
        let folder = Self.folder.resolvingSymlinksInPath().path
        #expect(transcript.text.contains(folder))
    }

    @Test func typedInputReachesTheProgramAndResizesAreSeen() async throws {
        let (terminal, transcript) = try run("read line; echo \"got:$line\"; read again; stty size")
        terminal.write(Data("hello\n".utf8))
        #expect(await transcript.waitFor("got:hello"))
        terminal.resize(.init(columns: 120, rows: 40))
        terminal.write(Data("\n".utf8))
        #expect(await transcript.exitCode() == 0)
        #expect(transcript.text.contains("40 120"))
        // Writing after the end is ignored.
        terminal.write(Data("late\n".utf8))
        terminal.resize(.init(columns: 1, rows: 1))
    }

    @Test func terminateHangsTheProgramUp() async throws {
        let (terminal, transcript) = try run("echo ready; while :; do sleep 1; done")
        #expect(await transcript.waitFor("ready"))
        terminal.terminate()
        #expect(await transcript.exitCode() == 128 + SIGHUP)
        terminal.terminate() // once finished, nothing more is sent
    }

    @Test func aProgramThatIgnoresTheHangUpIsKilled() async throws {
        let (terminal, transcript) = try run("trap '' HUP; echo ready; while :; do sleep 1; done")
        #expect(await transcript.waitFor("ready"))
        terminal.terminate()
        #expect(await transcript.exitCode() == 128 + SIGKILL)
    }

    @Test func aProgramThatCannotStartEndsWith127() async throws {
        let transcript = TerminalTranscript()
        let command = PseudoTerminal.Command(
            executable: "/nonexistent/program", arguments: [], environment: [:], directory: Self.folder)
        _ = try PseudoTerminal(
            command, size: .init(columns: 0, rows: 0), output: { transcript.append($0) },
            exit: { transcript.exited($0) })
        #expect(await transcript.exitCode() == 127)
    }

    @Test func exitCodesComeFromTheWaitStatus() {
        #expect(PseudoTerminal.exitCode(status: 0) == 0)
        #expect(PseudoTerminal.exitCode(status: 3 << 8) == 3)
        #expect(PseudoTerminal.exitCode(status: SIGHUP) == 129)
        #expect(PseudoTerminal.Size(columns: 0, rows: -2).window.ws_col == 1)
    }
}

@Suite("Terminal shell")
struct TerminalShellTests {
    private static let folder = URL(fileURLWithPath: "/tmp/checkout", isDirectory: true)

    @Test func theLoginShellIsTheAccountsWithALoginName() {
        let command = TerminalShell.login(in: Self.folder, inherited: ["PATH": "/bin"], userShell: "/opt/fish")
        #expect(command.executable == "/opt/fish")
        #expect(command.arguments == ["-fish"])
        #expect(command.directory == Self.folder)
        #expect(command.environment["SHELL"] == "/opt/fish")
        #expect(command.environment["PATH"] == "/bin")
        for shell in [nil, "", "fish"] {
            #expect(TerminalShell.login(in: Self.folder, inherited: [:], userShell: shell).arguments == ["-zsh"])
        }
    }

    @Test func theEnvironmentIsAColourXtermAndKeepsAChosenLocale() {
        let plain = TerminalShell.environment(["TERM": "dumb", "NO": "1"], shell: "/bin/zsh")
        #expect(plain["TERM"] == "xterm-256color")
        #expect(plain["COLORTERM"] == "truecolor")
        #expect(plain["TERM_PROGRAM"] == "Gita")
        #expect(plain["LANG"] == "en_US.UTF-8")
        #expect(plain["NO"] == "1")
        let chosen = TerminalShell.environment(["LC_ALL": "fr_FR.UTF-8"], shell: "/bin/zsh")
        #expect(chosen["LANG"] == nil)
    }

    @Test func aScriptRunsDirectlyInItsFolder() {
        let script = URL(fileURLWithPath: "/tmp/review.command")
        let command = TerminalShell.script(script, in: Self.folder, inherited: [:], userShell: nil)
        #expect(command.executable == script.path)
        #expect(command.arguments == [script.path])
        #expect(command.environment["SHELL"] == "/bin/zsh")
        #expect(TerminalShell.accountShell()?.hasPrefix("/") == true)
    }
}
