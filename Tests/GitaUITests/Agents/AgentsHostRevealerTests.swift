import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Which app shows an agent's terminal and how its tab is brought forward. The process table, running apps,
/// activation and the Orca CLI are fakes: nothing is activated.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentsHostRevealerTests {
    private static func session(pid: Int32?, title: String? = nil) -> AgentSession {
        AgentSession(
            id: "s", tool: .claudeCode, pid: pid, workingDirectory: URL(fileURLWithPath: "/w"), state: .working,
            stateSince: Date(), evidence: .process, title: title)
    }

    /// pid 10 is the agent, 20 its shell, 30 the app.
    private static func revealer(
        apps: [Int32: AgentHostRevealer.App], paths: [Int32: String] = [:], activates: Bool = true,
        orcaInstalled: Bool = true, switches: AgentsEvents<String> = AgentsEvents()
    ) -> AgentHostRevealer {
        AgentHostRevealer(
            switchOrcaTerminal: { checkout, title in switches.yield(checkout.path + "|" + (title ?? "")) },
            lineage: { [$0, 20, 30] }, executablePath: { paths[$0] }, app: { apps[$0] }, activate: { _ in activates },
            activateOrca: { orcaInstalled })
    }

    @Test func theNearestRegularAppAmongTheAncestorsHostsTheAgent() {
        let terminal = AgentHostRevealer.App(bundleIdentifier: OpenIn.defaultTerminal, isCandidate: true)
        let background = AgentHostRevealer.App(bundleIdentifier: "x.helper", isCandidate: false)
        let revealer = Self.revealer(apps: [20: background, 30: terminal])
        #expect(revealer.host(of: Self.session(pid: 10)) == .app(30))
        #expect(revealer.host(of: Self.session(pid: nil)) == nil)
        #expect(Self.revealer(apps: [:]).host(of: Self.session(pid: 10)) == nil)
        let orca = AgentHostRevealer.App(bundleIdentifier: BrandMarks.orca, isCandidate: true)
        #expect(Self.revealer(apps: [30: orca]).host(of: Self.session(pid: 10)) == .orca)
        let hosted = Self.revealer(apps: [30: terminal], paths: [20: "/Applications/Orca.app/Contents/MacOS/x"])
        #expect(hosted.host(of: Self.session(pid: 10)) == .orca)
    }

    @Test func orcaExecutablesAreRecognised() {
        #expect(AgentHostRevealer.isOrcaExecutable("/usr/local/lib/orca/orca-terminal-host"))
        #expect(AgentHostRevealer.isOrcaExecutable("/Applications/Orca.app/Contents/Resources/node"))
        #expect(!AgentHostRevealer.isOrcaExecutable("/bin/zsh"))
    }

    @Test func revealingInTerminalBringsTheAppForward() {
        let terminal = AgentHostRevealer.App(bundleIdentifier: OpenIn.defaultTerminal, isCandidate: true)
        #expect(Self.revealer(apps: [30: terminal]).reveal(Self.session(pid: 10)))
        #expect(!Self.revealer(apps: [30: terminal], activates: false).reveal(Self.session(pid: 10)))
        #expect(!Self.revealer(apps: [:]).reveal(Self.session(pid: 10)))
    }

    @Test func revealingInOrcaSwitchesToTheCheckoutsTerminal() async {
        let switches = AgentsEvents<String>()
        let orca = AgentHostRevealer.App(bundleIdentifier: BrandMarks.orca, isCandidate: true)
        let revealer = Self.revealer(apps: [30: orca], switches: switches)
        #expect(revealer.reveal(Self.session(pid: 10, title: "Task")))
        #expect(await switches.next() == "/w|Task")
        #expect(!Self.revealer(apps: [30: orca], orcaInstalled: false).reveal(Self.session(pid: 10)))
    }
}
