import Darwin
import Foundation
import Testing

@testable import GitaCore

private final class HelperLocator {}

/// `gita-agent` argument parsing, its stdin budget, the chained Codex program, and the built helper end to end.
@Suite struct AgentHelperInvocationTests {
    private static let payload = #"{"type":"agent-turn-complete","thread-id":"t9","cwd":"/tmp"}"#

    @Test(arguments: [
        ([String](), false), (["event", "claudeCode"], false), (["hook", "claudeCode", "Stop"], false),
        (["event", "unknownTool", "Stop"], false), (["event", "claudeCode", "Stop"], true),
        (["event", "gemini", "Stop"], true),
    ])
    func onlyEventCallsForKnownToolsParse(arguments: [String], parses: Bool) {
        #expect((AgentHelperInvocation(arguments: arguments) != nil) == parses)
    }

    @Test func codexChainsTheOriginalProgramWithThePayload() throws {
        let invocation = try #require(
            AgentHelperInvocation(arguments: [
                "event", "codex", "notify", "--then", "python3", "notify.py", "--flag", Self.payload,
            ]))
        #expect(invocation.chained == ["python3", "notify.py", "--flag"])
        #expect(invocation.payload == Self.payload)
        #expect(invocation.chainedCommand == ["python3", "notify.py", "--flag", Self.payload])
        #expect(!invocation.readsStandardInput)
        let event = try #require(invocation.hookEvent(input: Data("ignored".utf8), pids: [4_242]))
        #expect(event.tool == .codex && event.sessionID == "t9" && event.effect == .done)

        let plain = try #require(AgentHelperInvocation(arguments: ["event", "codex", "notify"]))
        #expect(plain.chainedCommand.isEmpty && plain.payload == nil)
        let unpaid = try #require(AgentHelperInvocation(arguments: ["event", "codex", "notify", "--then", "/bin/x"]))
        #expect(unpaid.chainedCommand == ["/bin/x"])
    }

    @Test func claudeReadsStandardInputAndNeverChains() throws {
        let invocation = try #require(
            AgentHelperInvocation(arguments: ["event", "claudeCode", "Notification", "--then", "/bin/x", "{}"]))
        #expect(invocation.readsStandardInput)
        #expect(invocation.chainedCommand.isEmpty)
        let input = Data(#"{"session_id":"s1","cwd":"/tmp","notification_type":"permission_prompt"}"#.utf8)
        let event = try #require(invocation.hookEvent(input: input, pids: []))
        #expect(event.tool == .claudeCode && event.event == "Notification" && event.effect == .needsInput)
    }

    @Test(arguments: [AgentTool.opencode, .aider, .gemini, .antigravity, .cursorAgent])
    func toolsWithoutHooksReportNothing(tool: AgentTool) throws {
        let invocation = try #require(AgentHelperInvocation(arguments: ["event", tool.rawValue, "Stop"]))
        #expect(invocation.hookEvent(input: Data("{}".utf8), pids: []) == nil)
        #expect(!invocation.readsStandardInput && invocation.chainedCommand.isEmpty)
    }

    @Test func socketPathsHonourOnlyAnAbsoluteOverride() {
        let defaults = [
            AgentEventSocket.path(development: false, home: "/Users/u"),
            AgentEventSocket.path(development: true, home: "/Users/u"),
        ]
        #expect(AgentHelperInvocation.socketPaths(environment: [:], home: "/Users/u") == defaults)
        #expect(
            AgentHelperInvocation.socketPaths(environment: ["GITA_AGENT_SOCKET": "/tmp/s.sock"], home: "/Users/u")
                == ["/tmp/s.sock"])
        #expect(
            AgentHelperInvocation.socketPaths(environment: ["GITA_AGENT_SOCKET": "relative"], home: "/Users/u")
                == defaults)
    }

    // MARK: Standard input

    private static func pipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        try #require(Darwin.pipe(&descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }

    @Test func readsWhatIsWrittenEvenWithThePipeLeftOpen() throws {
        let (reader, writer) = try Self.pipe()
        defer { close(reader) }
        defer { close(writer) }
        _ = Array("hello".utf8).withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        let start = ContinuousClock.now
        let data = AgentHookInput.read(reader, budget: .milliseconds(100))
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func aSpentBudgetStillReadsWhatIsReady() throws {
        let (reader, writer) = try Self.pipe()
        defer { close(reader) }
        _ = Array("ready".utf8).withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        close(writer)
        #expect(String(decoding: AgentHookInput.read(reader, budget: .zero), as: UTF8.self) == "ready")
    }

    @Test func inputArrivingWithinTheBudgetIsReadAndTheLimitHolds() async throws {
        let (reader, writer) = try Self.pipe()
        defer { close(reader) }
        let late = Task.detached {
            try await Task.sleep(for: .milliseconds(30))
            _ = Array("0123456789".utf8).withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            close(writer)
        }
        let data = AgentHookInput.read(reader, limit: 4, budget: .seconds(2))
        try await late.value
        #expect(String(decoding: data, as: UTF8.self) == "0123")
    }

    // MARK: Chained program

    private static func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aBareProgramNameIsFoundInPath() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("GitaChain-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        #expect(DetachedProgram.spawn(["sh", "-c", "printf %s \"$1\" > \"$0\"", marker.path, "payload"]) != nil)
        try await Self.waitForFile(marker)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "payload")
        #expect(DetachedProgram.spawn([]) == nil)
        #expect(DetachedProgram.spawn(["sh", "bad\0argument"]) == nil)
        #expect(DetachedProgram.spawn(["gita-no-such-program-anywhere"]) == nil)
    }

    /// The built helper, run as Codex runs it, with a chained program found by bare name that prints on both
    /// streams: none of it may reach the helper's stdout or stderr.
    @Test func theHelperChainsABareProgramAndStaysSilent() async throws {
        let helper = Bundle(for: HelperLocator.self).bundleURL.deletingLastPathComponent().appendingPathComponent(
            AgentHookInstaller.helperName)
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "Build gita-agent first")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("GitaChain-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helper
        process.arguments = [
            "event", "codex", "notify", "--then", "sh", "-c",
            "echo leaked; echo leaked >&2; printf %s \"$1\" > \"$0\"", marker.path, Self.payload,
        ]
        process.environment = [
            "GITA_AGENT_SOCKET": "/tmp/gp-none-\(UUID().uuidString.prefix(8)).sock", "PATH": "/usr/bin:/bin",
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try await Self.waitForFile(marker)
        #expect(try String(contentsOf: marker, encoding: .utf8) == Self.payload)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
