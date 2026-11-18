import Foundation
import XCTest

@testable import GitaCore

/// The agent skill install/update/remove cycle against a temporary HOME (the real `~/.claude` and `~/.codex` are never
/// touched), and the version lines the setup screen shows.
final class SetupEnvironmentTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaSkills-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testSkillInstallsAndUpdatesOnlyItsOwnFile() throws {
        let installer = AgentSkillInstaller(home: home)
        guard case .unavailable = installer.status(.claudeCode) else {
            XCTFail("No ~/.claude: Claude Code is not set up")
            return
        }
        XCTAssertThrowsError(try installer.install(.claudeCode))

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(installer.status(.claudeCode), .notInstalled)
        try installer.install(.claudeCode)
        XCTAssertEqual(installer.status(.claudeCode), .installed)
        let file = try XCTUnwrap(installer.skillFile(.claudeCode))
        XCTAssertEqual(file.path, home.appendingPathComponent(".claude/skills/gita/SKILL.md").path)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("---\nname: gita\n"))

        // An older Gita version of the skill is offered as an update, then replaced.
        try Data((AgentSkillInstaller.content + "\nold line\n").utf8).write(to: file)
        XCTAssertEqual(installer.status(.claudeCode), .needsUpdate)
        try installer.install(.claudeCode)
        XCTAssertEqual(installer.status(.claudeCode), .installed)
    }

    func testSomeoneElsesGitaSkillIsNeverReplacedOrRemoved() throws {
        let installer = AgentSkillInstaller(home: home)
        let file = try XCTUnwrap(installer.skillFile(.codex))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = "---\nname: gita\ndescription: mine\n---\n"
        try Data(theirs.utf8).write(to: file)
        guard case .unavailable = installer.status(.codex) else {
            XCTFail("A foreign skill is not ours to manage")
            return
        }
        XCTAssertThrowsError(try installer.install(.codex)) { XCTAssertEqual($0 as? AgentSkillError, .foreign(.codex)) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), theirs)
    }

    func testVersionLines() {
        XCTAssertEqual(SetupProbe.version("git version 2.47.1 (Apple Git-154)\n"), "2.47.1")
        XCTAssertEqual(
            SetupProbe.version("gh version 2.63.0 (2024-11-27)\nhttps://github.com/cli/cli/releases/tag/v2.63.0\n"),
            "2.63.0")
        XCTAssertEqual(SetupProbe.version("Vercel CLI 39.1.1\n39.1.1\n"), "39.1.1")
        XCTAssertNil(SetupProbe.version(""))
    }
}
