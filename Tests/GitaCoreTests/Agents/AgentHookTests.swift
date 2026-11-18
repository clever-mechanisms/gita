import Foundation
import XCTest

@testable import GitaCore

/// Hook events (decode, privacy, socket), the helper end to end, and the settings.json / config.toml edits.
/// Every file test runs against a temporary HOME; the real `~/.claude` and `~/.codex` are never touched.
final class AgentHookTests: XCTestCase {
    private var home: URL!
    private let helper = "/Applications/Gita.app/Contents/Helpers/gita-agent"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaHooks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    // MARK: Events

    func testClaudeEventsMapToStatesAndNeverCarryPromptContent() throws {
        let input = Data(
            #"""
            {"session_id":"abc-123","transcript_path":"/Users/u/.claude/projects/x/abc.jsonl",\#
            "cwd":"/Users/u/projects/app","hook_event_name":"UserPromptSubmit","prompt":"SECRET PROMPT TEXT"}
            """#
            .utf8)
        let event = AgentHookEvent.claude(event: "UserPromptSubmit", input: input, pids: [4242, 1, 4100])
        XCTAssertEqual(event.effect, .working)
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/u/projects/app")
        XCTAssertEqual(event.pids, [4242, 4100], "launchd is never a candidate owner")
        let wire = String(decoding: event.encoded(), as: UTF8.self)
        XCTAssertFalse(wire.contains("SECRET"))
        XCTAssertFalse(wire.contains("transcript"))
        XCTAssertFalse(wire.contains("\n"), "One datagram, one line")
        XCTAssertEqual(AgentHookEvent.decode(event.encoded()), event)

        func effect(_ name: String, _ json: String) -> AgentHookEvent.Effect {
            AgentHookEvent.claude(event: name, input: Data(json.utf8), pids: []).effect
        }
        XCTAssertEqual(
            effect(
                "Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission"}"#),
            .needsInput)
        XCTAssertEqual(
            effect("Notification", #"{"notification_type":"idle_prompt"}"#), .ignored,
            "The 60 s reminder after a finished turn is not a new request")
        XCTAssertEqual(effect("Notification", "{}"), .needsInput)
        XCTAssertEqual(effect("Stop", "{}"), .done)
        XCTAssertEqual(
            effect("SessionEnd", #"{"reason":"clear"}"#), .cleared,
            "/clear keeps the process and starts a new conversation")
        XCTAssertEqual(effect("SessionEnd", #"{"reason":"prompt_input_exit"}"#), .ended)
        XCTAssertEqual(effect("PreToolUse", "{}"), .ignored)
        // Unreadable stdin (truncated, not JSON) still reports the event so the pid chain can match it.
        XCTAssertEqual(AgentHookEvent.claude(event: "Stop", input: Data("{\"session_".utf8), pids: [9]).effect, .done)
    }

    func testCodexNotifyKeepsOnlyTypeThreadAndFolder() {
        let payload =
            #"""
            {"type":"agent-turn-complete","thread-id":"t-1","turn-id":"9","cwd":"/Users/u/repo",\#
            "input-messages":["fix it"],"last-assistant-message":"PRIVATE ANSWER"}
            """#
        let event = AgentHookEvent.codex(argument: payload, pids: [77])
        XCTAssertEqual(event.effect, .done)
        XCTAssertEqual(event.sessionID, "t-1")
        XCTAssertFalse(String(decoding: event.encoded(), as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(AgentHookEvent.codex(argument: #"{"type":"approval-requested"}"#, pids: []).effect, .ignored)
    }

    func testDecodeRejectsMalformedOversizedAndUnsafeFields() {
        XCTAssertNil(AgentHookEvent.decode(Data("not json".utf8)))
        XCTAssertNil(
            AgentHookEvent.decode(Data(#"{"version":2,"tool":"codex","event":"notify","pids":[],"time":1}"#.utf8)))
        XCTAssertNil(AgentHookEvent.decode(Data(#"{"version":1,"tool":"vim","event":"Stop","pids":[],"time":1}"#.utf8)))
        XCTAssertNil(AgentHookEvent.decode(Data(repeating: 0x20, count: AgentEventSocket.maximumMessage + 1)))
        let relative = AgentHookEvent.decode(
            Data(
                #"""
                {"version":1,"tool":"claudeCode","event":"Stop","cwd":"../etc","sessionID":"a\nb","pids":[0,-1,5],\#
                "time":1}
                """#
                .utf8))
        XCTAssertNil(relative?.cwd)
        XCTAssertNil(relative?.sessionID)
        XCTAssertEqual(relative?.pids, [5])
    }

    func testDatagramReachesListenerAndMissingSocketIsHarmless() throws {
        let path = shortSocketPath()
        let received = expectation(description: "event")
        let box = EventBox()
        let listener = try AgentEventListener(path: path) { event in
            box.event = event
            received.fulfill()
        }
        defer { listener.cancel() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let event = AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "s", cwd: "/tmp", pids: [123])
        AgentEventSocket.send(event.encoded(), to: [path + ".missing", path])
        wait(for: [received], timeout: 2)
        XCTAssertEqual(box.event, event)
    }

    /// Runs the built helper the way Claude Code and Codex run it: silent, exit 0, fast even with stdin left open,
    /// and Codex's original notify program still receives the payload.
    func testHelperIsSilentFastAndChainsOriginalCodexNotify() throws {
        let helperURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(
            AgentHookInstaller.helperName)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw XCTSkip("Build the gita-agent product first (swift build)")
        }
        let path = shortSocketPath()
        let received = expectation(description: "events")
        received.expectedFulfillmentCount = 2
        let box = EventBox()
        let listener = try AgentEventListener(path: path) { event in
            box.append(event)
            received.fulfill()
        }
        defer { listener.cancel() }

        let claude = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        claude.executableURL = helperURL
        claude.arguments = ["event", "claudeCode", "Notification"]
        claude.environment = ["GITA_AGENT_SOCKET": path]
        claude.standardInput = stdin
        claude.standardOutput = stdout
        let started = Date()
        try claude.run()
        stdin.fileHandleForWriting.write(
            Data(#"{"session_id":"s1","cwd":"/tmp","notification_type":"permission_prompt"}"#.utf8))
        // stdin intentionally left open: the helper must not wait for EOF beyond its deadline.
        claude.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(claude.terminationStatus, 0)
        XCTAssertTrue(
            stdout.fileHandleForReading.availableData.isEmpty,
            "Anything on stdout would be injected into the Claude session")

        let marker = home.appendingPathComponent("chained.txt")
        let codex = Process()
        codex.executableURL = helperURL
        codex.arguments = [
            "event", "codex", "notify", "--then", "/bin/sh", "-c", "printf %s \"$1\" > \"$0\"", marker.path,
            #"{"type":"agent-turn-complete","thread-id":"t9","cwd":"/tmp"}"#,
        ]
        codex.environment = ["GITA_AGENT_SOCKET": path]
        try codex.run()
        codex.waitUntilExit()
        XCTAssertEqual(codex.terminationStatus, 0)
        wait(for: [received], timeout: 3)
        XCTAssertEqual(box.events.map(\.effect).sorted { $0.rawValue < $1.rawValue }, [.done, .needsInput])
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: marker.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(
            try? String(contentsOf: marker, encoding: .utf8),
            #"{"type":"agent-turn-complete","thread-id":"t9","cwd":"/tmp"}"#)
        stdin.fileHandleForWriting.closeFile()
    }

    private func shortSocketPath() -> String {
        // sockaddr_un holds 104 bytes; the per-user temporary folder is long, /tmp is not.
        "/tmp/gp-\(UUID().uuidString.prefix(8)).sock"
    }

    // MARK: Claude Code settings.json

    private var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    private func installer(_ helperPath: String? = nil) -> AgentHookInstaller {
        AgentHookInstaller(home: home, helperPath: helperPath ?? helper)
    }

    private func writeSettings(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: settings)
    }
    private func readSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }
    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }
    private func backups(_ file: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter {
            $0.contains(".gita-backup-")
        }
    }

    func testClaudeInstallKeepsForeignHooksIsIdempotentAndBacksUp() throws {
        try writeSettings(
            #"""
            {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"orca-hook stop"}]}],\#
            "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]},\#
            "permissions":{"allow":["Bash(git status)"]}}
            """#
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        XCTAssertEqual(installer().status(.claudeCode), .notInstalled)
        try installer().install(.claudeCode)
        try installer().install(.claudeCode)
        let root = try readSettings()
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["permissions"])
        XCTAssertEqual(commands(root, "PreToolUse"), ["guard.sh"])
        XCTAssertEqual(
            commands(root, "Stop"),
            ["orca-hook stop", "'/Applications/Gita.app/Contents/Helpers/gita-agent' event claudeCode Stop"])
        for event in AgentHookInstaller.claudeEvents {
            XCTAssertEqual(commands(root, event).filter { $0.contains("gita-agent") }.count, 1, event)
        }
        XCTAssertEqual(installer().status(.claudeCode), .installed)
        XCTAssertEqual(try backups(settings).count, 1, "The second, unchanged install writes nothing")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int,
            0o600)
    }

    func testClaudeRemovalTakesOnlyOurEntries() throws {
        try writeSettings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"orca-hook stop"}]}]}}"#)
        try installer().install(.claudeCode)
        try installer().remove(.claudeCode)
        let root = try readSettings()
        XCTAssertEqual(commands(root, "Stop"), ["orca-hook stop"])
        XCTAssertNil(
            (root["hooks"] as? [String: Any])?["UserPromptSubmit"], "Events we added are removed with our entry")
        XCTAssertEqual(installer().status(.claudeCode), .notInstalled)
        // A group shared with someone else's command loses only our command.
        try writeSettings(
            #"""
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"a.sh"},{"type":"command",\#
            "command":"'/x/gita-agent' event claudeCode Stop"}]}]}}
            """#
        )
        try installer().remove(.claudeCode)
        XCTAssertEqual(commands(try readSettings(), "Stop"), ["a.sh"])
    }

    func testClaudeStatusAsksForUpdateAfterTheAppMoved() throws {
        try writeSettings("{}")
        try installer("/Users/u/Downloads/Gita.app/Contents/Helpers/gita-agent").install(.claudeCode)
        XCTAssertEqual(installer().status(.claudeCode), .needsUpdate)
        try installer().install(.claudeCode)
        XCTAssertEqual(installer().status(.claudeCode), .installed)
        XCTAssertFalse(
            commands(try readSettings(), "Stop").contains { $0.contains("Downloads") },
            "Reinstall replaces the stale command")
    }

    func testClaudeInvalidSettingsAreNeverOverwrittenAndSymlinksAreFollowed() throws {
        try writeSettings(#"{"hooks": [1, 2"#)
        if case .unavailable = installer().status(.claudeCode) {
        } else {
            XCTFail("Invalid JSON must report unavailable")
        }
        XCTAssertThrowsError(try installer().install(.claudeCode))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), #"{"hooks": [1, 2"#)

        // Dotfile managers link settings.json; the link stays and its target gets the edit.
        let target = home.appendingPathComponent("dotfiles-settings.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        try installer().install(.claudeCode)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), target.path)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("gita-agent"))
    }

    func testClaudeWithoutClaudeFolderIsUnavailableAndUntouched() throws {
        if case .unavailable = installer().status(.claudeCode) {
        } else {
            XCTFail("A Claude Code folder that is a file makes the hooks unavailable")
        }
        XCTAssertThrowsError(try installer().install(.claudeCode)) {
            XCTAssertEqual($0 as? AgentHookError, .toolMissing(.claudeCode))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.deletingLastPathComponent().path))
        if case .unavailable = installer().status(.aider) {} else { XCTFail("Tools without hooks report unavailable") }
    }

    // MARK: Codex config.toml

    private var config: URL { home.appendingPathComponent(".codex/config.toml") }
    private func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: config)
    }

    func testCodexInstallChainsExistingNotifyAndRemovalRestoresItExactly() throws {
        let original = """
            model = "gpt-5"
            notify = ["/Users/u/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient", \
            "turn-ended"]

            [desktop]
            enabled = true
            """
        try writeConfig(original)
        try installer().install(.codex)
        let installed = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(
            installed.contains(
                #"""
                notify = ["/Applications/Gita.app/Contents/Helpers/gita-agent", "event", "codex", \#
                "notify", "--then", \#
                "/Users/u/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient", \#
                "turn-ended"]
                """#
            ))
        XCTAssertTrue(installed.hasSuffix("[desktop]\nenabled = true"))
        XCTAssertEqual(installer().status(.codex), .installed)
        try installer().install(.codex)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), installed, "Reinstall does not chain itself")
        try installer().remove(.codex)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
        XCTAssertEqual(try backups(config).count, 2)
    }

    func testCodexInsertGoesAboveTablesAndIgnoresLookalikes() throws {
        let original = """
            # notify = ["commented out"]
            profiles_note = '''
            [not a table]
            notify = "inside a string"
            '''
            matrix = [
              ["a", "b"],
            ]

            [profiles.fast]
            notify = ["a table key, not the top-level one"]
            """
        try writeConfig(original)
        XCTAssertEqual(installer().status(.codex), .notInstalled)
        try installer().install(.codex)
        let installed = try String(contentsOf: config, encoding: .utf8)
        let insertion = try XCTUnwrap(installed.range(of: "notify = [\"/Applications"))
        let table = try XCTUnwrap(installed.range(of: "[profiles.fast]"))
        XCTAssertLessThan(insertion.lowerBound, table.lowerBound)
        XCTAssertGreaterThan(insertion.lowerBound, try XCTUnwrap(installed.range(of: "matrix = [")).lowerBound)
        try installer().remove(.codex)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    func testCodexNotifyThatIsNotAStringArrayIsLeftAlone() throws {
        try writeConfig("notify = \"/usr/local/bin/notifier\"\n")
        XCTAssertThrowsError(try installer().install(.codex))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "notify = \"/usr/local/bin/notifier\"\n")
        XCTAssertEqual(installer().status(.codex), .notInstalled)
        // An empty or missing config gets a single top-level line.
        try writeConfig("")
        try installer().install(.codex)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            """
            notify = [\"/Applications/Gita.app/Contents/Helpers/gita-agent\", \"event\", \"codex\", \
            \"notify\"]\n
            """
        )
        try installer().remove(.codex)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "")
    }

    func testTOMLStringsRoundTripEscapes() {
        let values = ["/path with \"quotes\"", #"C:\tmp"#, "tab\there", "é"]
        let rendered = TOMLNotify.render(values) + "\n"
        XCTAssertEqual(TOMLNotify.find(in: rendered)?.values, values)
        XCTAssertEqual(TOMLNotify.find(in: "notify = ['literal \\n', \"x\"]")?.values, ["literal \\n", "x"])
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentHookEvent] = []
    var event: AgentHookEvent? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored.last
        }
        set {
            lock.lock()
            stored = newValue.map { [$0] } ?? []
            lock.unlock()
        }
    }
    var events: [AgentHookEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ event: AgentHookEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }
}
