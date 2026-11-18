import Foundation

@testable import GitaCore

/// Runs Git for real but hands its editor invocations back to this test process. The app is its own rebase editor
/// (Git starts the app's executable with `--gita-rebase-editor`); under `swift test` that executable is the test
/// runner, so a small shell editor posts each request to a folder and waits while this process answers it with
/// `GitRebaseEditor.handleInvocation`, exactly as the app would.
struct RebaseEditorBridge: CommandRunning {
    let folder: URL
    private let runner = CommandRunner()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaRebaseBridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            request="\(folder.path)/request.$$"
            printf '%s\\n%s\\n%s\\n%s\\n' "$1" "$2" "$3" "$4" > "$request.tmp"
            mv "$request.tmp" "$request"
            while [ ! -f "$request.done" ]; do sleep 0.01; done
            status=$(cat "$request.done")
            rm -f "$request.done" "$request.served"
            exit "$status"

            """
        try Data(script.utf8).write(to: editor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor.path)
    }

    private var editor: URL { folder.appendingPathComponent("editor.sh") }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard let editors = request.editors else { return try await runner.run(request) }
        var bridged = request
        bridged.editors = GitEditorEnvironment(
            editor: try redirect(editors.editor), sequenceEditor: try redirect(editors.sequenceEditor))
        let folder = folder
        let server = Task.detached {
            while !Task.isCancelled {
                Self.answer(in: folder)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { server.cancel() }
        return try await runner.run(bridged)
    }

    /// `'<app>' '--gita-rebase-editor' '<mode>' '<git dir>' '<id>'` becomes `'<editor.sh>' '<mode>' …`.
    private func redirect(_ command: String) throws -> String {
        let quoted = "'" + editor.path + "' "
        guard let flag = command.range(of: "'" + GitRebaseEditor.argument + "' ") else {
            throw CommandError.invalidArgument
        }
        return quoted + command[flag.upperBound...]
    }

    private static func answer(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("request.") && !name.contains(".", after: "request.") {
            let request = folder.appendingPathComponent(name)
            let served = folder.appendingPathComponent(name + ".served")
            guard (try? FileManager.default.moveItem(at: request, to: served)) != nil,
                let text = try? String(contentsOf: served, encoding: .utf8)
            else { continue }
            let fields = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let status =
                fields.count >= 4
                ? GitRebaseEditor.handleInvocation(
                    arguments: ["gita", GitRebaseEditor.argument, fields[0], fields[1], fields[2], fields[3]]) ?? 1
                : 1
            try? Data("\(status)".utf8).write(to: folder.appendingPathComponent(name + ".done"), options: .atomic)
        }
    }
}

extension String {
    /// Whether a `.` follows `prefix` (a request file still being written or already answered).
    fileprivate func contains(_ character: Character, after prefix: String) -> Bool {
        dropFirst(prefix.count).contains(character)
    }
}
