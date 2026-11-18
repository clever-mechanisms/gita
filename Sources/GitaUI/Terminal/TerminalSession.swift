import Foundation
import GitaCore

/// A program on a pseudo-terminal, as the session sees it; `PseudoTerminal` in the app, a recording in tests.
protocol TerminalProcess: AnyObject, Sendable {
    func write(_ data: Data)
    func resize(_ size: PseudoTerminal.Size)
    func terminate()
}

extension PseudoTerminal: TerminalProcess {}

/// One built-in terminal: the program it runs in a folder, connected to the page that shows it. The program starts
/// when the page is ready (so it starts at the page's size); its output goes to the page in batches; once it ends,
/// Return starts a new login shell in the same folder.
///
/// Two lifecycles meet here: the program's (`state`) and the page's (`pageIsReady`). The page can load again while
/// the program runs (`pageWillReload`): output then waits until the page reports ready, at its new size.
@MainActor
final class TerminalSession {
    /// What the terminal runs first: the login shell, or a script (which removes itself, so a restart is a shell).
    enum Launch: Equatable {
        case shell
        case script(URL)
    }

    /// `closed` is final: the terminal was closed, and nothing starts in it again.
    enum State: Equatable { case waiting, running, ended, closed }

    typealias Output = @Sendable (Data) -> Void
    typealias Exit = @Sendable (Int32) -> Void
    /// Starts a command at a size; output and the exit code arrive on any queue.
    typealias Spawn =
        @MainActor (PseudoTerminal.Command, PseudoTerminal.Size, @escaping Output, @escaping Exit)
        throws -> any TerminalProcess
    /// Runs main-actor work later, in order: the main queue in the app, at once in tests.
    typealias Hop = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    static let spawnPseudoTerminal: Spawn = { command, size, output, exit in
        try PseudoTerminal(command, size: size, output: output, exit: exit)
    }
    static let mainQueue: Hop = { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } }

    let directory: URL
    private(set) var state = State.waiting
    /// A program runs in it, or is about to: closing it now would end that program.
    var isOpen: Bool { state == .waiting || state == .running }
    /// Runs JavaScript in the page; set by the view that shows the session.
    var evaluate: ((String) -> Void)?
    /// The program set the terminal's title.
    var onTitle: ((String) -> Void)?
    /// Removes a script the session closed before running (a running script removes itself).
    var discardScript: (URL) -> Void = { ReviewScripts.discard($0) }

    private var launch: Launch
    private let spawn: Spawn
    private let hop: Hop
    private let makeCommand: (Launch, URL) -> PseudoTerminal.Command
    private var process: (any TerminalProcess)?
    private var size = PseudoTerminal.Size(columns: 80, rows: 24)
    private var pending = Data()
    private var flushScheduled = false
    /// The page reported ready and has not started loading again since: it can take output.
    private(set) var pageIsReady = false

    init(
        directory: URL, launch: Launch = .shell, spawn: @escaping Spawn = spawnPseudoTerminal,
        hop: @escaping Hop = mainQueue,
        makeCommand: @escaping (Launch, URL) -> PseudoTerminal.Command = { command($0, in: $1) }
    ) {
        self.directory = directory
        self.launch = launch
        self.spawn = spawn
        self.hop = hop
        self.makeCommand = makeCommand
    }

    /// The login shell or the script, in `directory`.
    static func command(_ launch: Launch, in directory: URL) -> PseudoTerminal.Command {
        switch launch {
        case .shell: TerminalShell.login(in: directory)
        case .script(let script): TerminalShell.script(script, in: directory)
        }
    }

    func handle(_ message: TerminalMessage) {
        switch message {
        case .ready(let size):
            self.size = size
            pageIsReady = true
            if state == .waiting {
                start()
            } else {
                process?.resize(size)
                flush()
            }
        case .resize(let size):
            self.size = size
            process?.resize(size)
        case .input(let data):
            if state == .ended {
                restart(after: data)
            } else {
                process?.write(data)
            }
        case .title(let title):
            onTitle?(title)
        }
    }

    /// The terminal closed: hangs the program up (as closing a terminal window does) and starts nothing again, even
    /// when the page reports in late.
    func terminate() {
        if state == .waiting, case .script(let script) = launch { discardScript(script) }
        launch = .shell
        state = .closed
        pending.removeAll()
        process?.terminate()
        process = nil
    }

    /// The page is loading again (its web content process ended): output waits for it to report ready.
    func pageWillReload() { pageIsReady = false }

    // MARK: Running

    private func start() {
        let command = makeCommand(launch, directory)
        launch = .shell
        let hop = hop
        do {
            process = try spawn(
                command, size,
                { [weak self] data in hop { self?.received(data) } },
                { [weak self] code in hop { self?.ended(code) } })
            state = .running
        } catch {
            state = .ended
            show(TerminalText.couldNotStart(command.executable, error) + "\r\n" + TerminalText.restartHint)
        }
    }

    /// Return after the program ended starts a new shell; other keys do nothing.
    private func restart(after data: Data) {
        guard data.contains(0x0d) else { return }
        // A soft reset undoes modes a full-screen program may have left on (mouse reports, hidden cursor…).
        show("\u{1b}[!p\r\n")
        start()
    }

    private func ended(_ code: Int32) {
        guard state != .closed else { return }
        process = nil
        state = .ended
        show("\r\n" + TerminalText.ended(code) + "\r\n" + TerminalText.restartHint + "\r\n")
    }

    // MARK: Output

    private func received(_ data: Data) {
        pending.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        hop { [weak self] in self?.flush() }
    }

    private func show(_ text: String) {
        pending.append(Data(text.utf8))
        flush()
    }

    /// Everything received since the last flush, in one call to the page.
    private func flush() {
        flushScheduled = false
        guard pageIsReady, state != .closed, !pending.isEmpty else { return }
        evaluate?("gita.write('\(pending.base64EncodedString())')")
        pending.removeAll(keepingCapacity: true)
    }
}

/// The lines the terminal itself prints, dimmed like Terminal's.
enum TerminalText {
    static func ended(_ code: Int32) -> String {
        let text =
            code == 0
            ? String(localized: "[Process completed]") : String(localized: "[Process exited with code \(Int(code))]")
        return dim(text)
    }

    static var restartHint: String { dim(String(localized: "Press Return to start a new shell.")) }

    static func couldNotStart(_ program: String, _ error: any Error) -> String {
        dim(String(localized: "Couldn’t start \(program): \(error.localizedDescription)"))
    }

    private static func dim(_ text: String) -> String { "\u{1b}[2m" + text + "\u{1b}[0m" }
}
