import Foundation

/// Commit signature inspection and repo-local signing configuration via `git`.
extension GitService {
    /// Reads signature verification status, signer, key ID, and fingerprint for `ref`.
    /// Passes `--no-show-signature` so a user's `log.showSignature=true` does not prepend prose lines.
    public func commitSignature(for ref: String) async throws -> CommitSignatureInfo {
        let sha = try await resolveCommit(ref)
        let result = try await execute(
            ["log", "-1", "--no-show-signature", "--format=%G?%x00%GS%x00%GK%x00%GF", sha],
            timeout: 15,
            outputLimit: 64 * 1_024
        )
        return Self.parseCommitSignature(result.stdout)
    }

    /// Reads effective and repo-local commit signing configuration.
    public func signingConfig() async throws -> CommitSigningConfig {
        async let effectiveEnabled = readBoolConfig(key: "commit.gpgsign", localOnly: false)
        async let localEnabled = readBoolConfig(key: "commit.gpgsign", localOnly: true)
        async let formatValue = readStringConfig(key: "gpg.format")
        async let keyValue = readStringConfig(key: "user.signingkey")

        let (enabled, local, format, key) = try await (effectiveEnabled, localEnabled, formatValue, keyValue)
        return CommitSigningConfig(
            isEnabled: enabled.boolValue,
            isRepoLocalOverride: local.isSet,
            format: CommitSigningFormat(gitConfigValue: format),
            signingKey: key
        )
    }

    /// Sets repo-local `commit.gpgsign` explicitly on user request.
    public func setLocalCommitSigning(_ enabled: Bool) async throws {
        try await mutate(["config", "--local", "commit.gpgsign", enabled ? "true" : "false"])
    }

    /// Reads `commit.template` (path-expanded by Git) and `core.commentChar`.
    public func commitTemplateSettings() async -> (path: String?, commentChar: String) {
        let templatePath = try? await readStringConfig(key: "commit.template", pathExpanded: true)
        let commentChar = (try? await readStringConfig(key: "core.commentChar")) ?? "#"
        return (templatePath, commentChar)
    }

    /// Reads a concise `--stat` summary for staged changes without running external diff/textconv drivers.
    public func stagedDiffStat() async throws -> String {
        let result = try await execute(
            ["diff", "--cached", "--stat"] + GitArguments.safeDiff,
            timeout: 15,
            outputLimit: 256 * 1_024
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the NUL-delimited output of `git log -1 --no-show-signature --format=%G?%x00%GS%x00%GK%x00%GF`.
    public static func parseCommitSignature(_ data: Data) -> CommitSignatureInfo {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !raw.isEmpty else { return .unsigned }
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let status = CommitSignatureStatus(gitCode: fields.first ?? "")
        guard status.isSigned else { return .unsigned }
        let signer = fields.count > 1 ? fields[1] : nil
        let keyID = fields.count > 2 ? fields[2] : nil
        let fingerprint = fields.count > 3 ? fields[3] : nil
        return CommitSignatureInfo(status: status, signer: signer, keyID: keyID, fingerprint: fingerprint)
    }

    private func readBoolConfig(key: String, localOnly: Bool) async throws -> GitBoolConfigState {
        let scope = localOnly ? ["--local"] : []
        let result = try await execute(
            ["config"] + scope + ["--type=bool", "--get", key],
            timeout: 10,
            outputLimit: 16 * 1_024,
            allowFailure: true
        )
        if result.exitCode == 1 { return .unset }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return .set(GitOutput.withoutTerminalLF(result.text).lowercased() == "true")
    }

    private func readStringConfig(key: String, pathExpanded: Bool = false) async throws -> String? {
        let typeArgs = pathExpanded ? ["--type=path"] : []
        let result = try await execute(
            ["config"] + typeArgs + ["--get", key],
            timeout: 10,
            outputLimit: 16 * 1_024,
            allowFailure: true
        )
        if result.exitCode == 1 { return nil }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        let value = GitOutput.withoutTerminalLF(result.text)
        return value.isEmpty ? nil : value
    }
}

private enum GitBoolConfigState: Sendable {
    case unset
    case set(Bool)

    var isSet: Bool {
        if case .set = self { return true }
        return false
    }

    var boolValue: Bool {
        if case .set(let flag) = self { return flag }
        return false
    }
}
