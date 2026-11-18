import Foundation

public struct CommandResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32
    /// Lossy UTF-8 for display; byte-exact work uses `stdout`.
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}
