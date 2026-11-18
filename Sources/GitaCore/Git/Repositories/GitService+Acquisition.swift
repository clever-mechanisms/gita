import Darwin
import Foundation

/// Creating a working copy: a new empty repository or a clone, always into a folder this call creates itself.
extension GitService {
    public static func initialize(
        at destination: URL, branch: String = "main", runner: any CommandRunning = CommandRunner()
    ) async throws -> URL {
        try Task.checkCancellation()
        try GitInput.validateReference(branch)
        let target = try acquisitionDestination(destination)
        let parent = target.deletingLastPathComponent()
        let checked = try await runner.run(
            CommandRequest.git(
                ["check-ref-format", "--branch", branch], directory: parent, timeout: 10, outputLimit: 64 * 1_024))
        guard checked.exitCode == 0 else { throw GitError.invalidReference }
        try Task.checkCancellation()
        try claimDestination(target)
        let result = try await runner.run(
            CommandRequest.git(
                GitArguments.noHooks + ["init", "--template=", "--initial-branch=" + branch, "--", target.path],
                directory: parent, timeout: 30, outputLimit: 1_024 * 1_024))
        guard result.exitCode == 0 else { throw failure(result) }
        return target
    }

    /// Inherited hooks and templates are disabled for this operation; existing CLI authentication is kept.
    public static func clone(
        remote: String, to destination: URL, runner: any CommandRunning = CommandRunner()
    ) async throws -> URL {
        try Task.checkCancellation()
        let source = try RemoteURLPolicy.validate(remote)
        let target = try acquisitionDestination(destination)
        try claimDestination(target)
        let options = ["--no-pager"] + GitArguments.transportAllowList + GitArguments.noHooks
        var request = CommandRequest.git(
            options + ["clone", "--no-local", "--template=", "--", source, target.path],
            directory: target.deletingLastPathComponent(), outputLimit: 8 * 1_024 * 1_024)
        GitTimeout.untilIdle.apply(to: &request)
        let result = try await runner.run(request)
        guard result.exitCode == 0 else { throw failure(result) }
        return target
    }

    private static func acquisitionDestination(_ destination: URL) throws -> URL {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.contains("\0") else {
            throw GitError.invalidPath
        }
        let standardized = destination.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        guard standardized.path != "/", !standardized.lastPathComponent.isEmpty else { throw GitError.invalidPath }
        var info = stat()
        guard stat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw GitError.invalidPath }
        return parent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }

    /// mkdir is atomic and refuses directories, files, and dangling symlinks alike. A failed or cancelled
    /// acquisition deliberately leaves the folder it created: cleanup must never remove files another process may
    /// have placed there.
    private static func claimDestination(_ target: URL) throws {
        guard mkdir(target.path, 0o700) == 0 else {
            if errno == EEXIST { throw GitError.destinationExists }
            throw LocalFileError.destinationNotCreated
        }
    }
}
