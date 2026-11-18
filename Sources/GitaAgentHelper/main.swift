import Darwin
import Foundation
import GitaCore

// gita-agent event <tool> <event> [--then <program> <arguments…>] [<codex notification JSON>]
//
// Runs as an agent hook. It forwards one small event (ids, cwd, no content) to Gita over a datagram socket and
// exits 0 within a few hundred milliseconds whatever happens: it must never block, fail or print into the agent's
// session. The parsing and every decision live in `AgentHelperInvocation`.

if let invocation = AgentHelperInvocation(arguments: Array(CommandLine.arguments.dropFirst())) {
    let input = invocation.readsStandardInput ? AgentHookInput.read(STDIN_FILENO) : Data()
    if !invocation.chainedCommand.isEmpty { DetachedProgram.spawn(invocation.chainedCommand) }
    let ancestors = Array(AgentProcessTable.ancestors(of: getpid(), limit: 8))
    if let event = invocation.hookEvent(input: input, pids: ancestors) {
        AgentEventSocket.send(
            event.encoded(),
            to: AgentHelperInvocation.socketPaths(
                environment: ProcessInfo.processInfo.environment, home: AgentEventSocket.userHome))
    }
}
exit(0)
