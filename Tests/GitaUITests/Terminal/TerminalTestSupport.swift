import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// A stand-in program: records what the session sends it and lets the test print and exit.
final class RecordedProcess: TerminalProcess, @unchecked Sendable {
    var written = Data()
    var sizes: [PseudoTerminal.Size] = []
    var terminated = false
    var output: TerminalSession.Output = { _ in }
    var exit: TerminalSession.Exit = { _ in }

    func write(_ data: Data) { written.append(data) }
    func resize(_ size: PseudoTerminal.Size) { sizes.append(size) }
    func terminate() { terminated = true }
}

/// A session wired to recorded processes, with its page calls collected as text.
@MainActor
final class SessionHarness {
    var started: [(PseudoTerminal.Command, PseudoTerminal.Size)] = []
    var processes: [RecordedProcess] = []
    var scripts: [String] = []
    var fails = false
    let folder: URL
    private let launch: TerminalSession.Launch
    private(set) lazy var session = makeSession()

    init(launch: TerminalSession.Launch = .shell, folder: URL = URL(fileURLWithPath: "/tmp/checkout")) {
        self.launch = launch
        self.folder = folder
    }

    /// The page reports in, so the session starts its (recorded) program.
    func ready() { session.handle(.ready(.init(columns: 80, rows: 24))) }

    private func makeSession() -> TerminalSession {
        let session = TerminalSession(
            directory: folder, launch: launch,
            spawn: { [weak self] command, size, output, exit in
                guard let self, !self.fails else { throw POSIXError(.ENOENT) }
                self.started.append((command, size))
                let process = RecordedProcess()
                process.output = output
                process.exit = exit
                self.processes.append(process)
                return process
            },
            hop: { work in MainActor.assumeIsolated { work() } },
            makeCommand: { launch, directory in
                let name =
                    switch launch {
                    case .shell: "shell"
                    case .script(let script): script.lastPathComponent
                    }
                return PseudoTerminal.Command(executable: name, arguments: [], environment: [:], directory: directory)
            })
        session.evaluate = { [weak self] in self?.scripts.append($0) }
        return session
    }

    /// Everything written to the page, as one byte stream (xterm.js joins characters split across writes).
    var shown: String { Self.shown(scripts) }

    /// The bytes `scripts` write to the page, as one string.
    static func shown(_ scripts: [String]) -> String {
        let bytes = scripts.compactMap { script -> Data? in
            guard script.hasPrefix("gita.write('") else { return nil }
            return Data(base64Encoded: String(script.dropFirst(12).dropLast(2)))
        }
        return String(decoding: bytes.reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
    }
}

/// An exit code reported on the terminal's queue.
final class TerminalExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?

    var value: Int32? { lock.withLock { code } }
    func set(_ code: Int32) { lock.withLock { self.code = code } }
}
