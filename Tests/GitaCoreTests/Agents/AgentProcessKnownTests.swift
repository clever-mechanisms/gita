import Darwin
import Foundation
import Testing

@testable import GitaCore

/// The scanner's cached verdict per pid holds only while the pid still names the process it was made for.
@Suite struct AgentProcessKnownTests {
    private typealias Known = AgentProcessScanner.Known
    private let claude = AgentProcessIdentity(tool: .claudeCode, isService: false)

    @Test func aNonAgentStaysKnownUntilItsParentOrNameChanges() {
        let known = Known.notAgent(parent: 10, name: "zsh")
        var reads = 0
        let start: () -> UInt64? = {
            reads += 1
            return 1
        }
        #expect(known.describes((parent: 10, hasTerminal: true, name: "zsh"), start: start))
        // `exec` changes the name; a reused pid usually has another parent.
        #expect(!known.describes((parent: 10, hasTerminal: true, name: "claude"), start: start))
        #expect(!known.describes((parent: 11, hasTerminal: true, name: "zsh"), start: start))
        #expect(reads == 0, "A non-agent never costs a start-time read")
        #expect(known.identity == nil)
    }

    @Test func anAgentStaysKnownWhileItsStartAndNameHold() {
        let known = Known.agent(name: "claude", start: 42, identity: claude)
        // Reparenting (its shell exited) does not change what the process is.
        #expect(known.describes((parent: 1, hasTerminal: false, name: "claude"), start: { 42 }))
        #expect(!known.describes((parent: 1, hasTerminal: false, name: "claude"), start: { 43 }))
        #expect(!known.describes((parent: 1, hasTerminal: false, name: "claude"), start: { nil }))
        #expect(!known.describes((parent: 1, hasTerminal: false, name: "zsh"), start: { 42 }))
        #expect(known.identity == claude)
    }

    /// A shell that `exec`s a stand-in agent keeps its pid: the second scan finds the agent the first scan did not.
    @Test func aProcessThatExecsIntoAnAgentIsFound() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaAgentExec-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let source = container.appendingPathComponent("agent.c")
        try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
        let fakeAgent = container.appendingPathComponent("claude").path
        let compiled = try await CommandRunner().run(
            executable: "cc", arguments: ["-O0", "-o", fakeAgent, source.path], timeout: 60)
        try #require(compiled.exitCode == 0, "No C compiler to build the stand-in agent")

        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read line; exec \"$0\"", fakeAgent]
        process.currentDirectoryURL = container
        process.standardInput = input
        try process.run()
        let pid = process.processIdentifier
        defer { kill(pid, SIGKILL) }

        let scanner = AgentProcessScanner()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !scanner.scan().contains { $0.pid == pid })
        input.fileHandleForWriting.write(Data("go\n".utf8))
        var found: AgentProcessSample?
        for _ in 0..<20 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            found = await scanner.scan().first { $0.pid == pid }
        }
        #expect(found?.tool == .claudeCode)
    }
}
