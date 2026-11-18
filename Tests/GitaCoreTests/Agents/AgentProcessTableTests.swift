import Darwin
import Foundation
import XCTest

@testable import GitaCore

/// `KERN_PROCARGS2` parsing on fixed buffers: the live scan reaches it only through interpreter processes (node,
/// python), which a CI runner does not have.
final class AgentProcessTableTests: XCTestCase {
    /// argc, the executable path, NUL padding, then the arguments.
    private func buffer(argc: Int32, executable: String, padding: Int = 3, _ arguments: [String]) -> ArraySlice<UInt8> {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(executable.utf8) + [UInt8](repeating: 0, count: padding)
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        return bytes[...]
    }

    func testArgumentsFollowTheExecutablePathAndItsPadding() {
        let bytes = buffer(argc: 2, executable: "/usr/local/bin/node", ["node", "/opt/agent/cli.js", "PATH=/bin"])
        XCTAssertEqual(AgentProcessTable.parseArguments(bytes, limit: 8), ["node", "/opt/agent/cli.js"])
    }

    func testTheLimitBoundsTheArguments() {
        let bytes = buffer(argc: 3, executable: "/usr/bin/python3", ["python3", "-m", "agent"])
        XCTAssertEqual(AgentProcessTable.parseArguments(bytes, limit: 2), ["python3", "-m"])
    }

    func testATruncatedBufferKeepsWhatItHas() {
        var bytes = Array(buffer(argc: 4, executable: "/bin/node", ["node", "script.js"]))
        bytes.removeLast() // the last argument loses its terminator
        XCTAssertEqual(AgentProcessTable.parseArguments(bytes[...], limit: 8), ["node", "script.js"])
        XCTAssertEqual(AgentProcessTable.parseArguments(buffer(argc: 1, executable: "/bin/node", []), limit: 8), [])
    }

    func testABufferWithoutRoomForArgcHasNoArguments() {
        XCTAssertEqual(AgentProcessTable.parseArguments([2, 0, 0, 0][...], limit: 8), [])
        XCTAssertEqual(AgentProcessTable.parseArguments([][...], limit: 8), [])
    }

    func testTheTestProcessReadsItsOwnArguments() {
        XCTAssertFalse(AgentProcessTable.arguments(getpid(), limit: 1).isEmpty)
    }
}
