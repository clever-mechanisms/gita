import Foundation

enum ControlPlaneLog {
    static func clean(_ raw: String) -> String {
        let normalized = LogRedactor.stripANSI(raw).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let filtered = normalized.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }
        return LogRedactor.redact(String(filtered))
    }

    static func suffix(_ text: String, bytes: Int) -> String {
        var tail = text.utf8.suffix(bytes)
        while let first = tail.first, first & 0xc0 == 0x80 { tail = tail.dropFirst() }
        return String(decoding: tail, as: UTF8.self)
    }
}

public enum CIFixLogSanitizer {
    public static func excerpt(_ raw: String, failedStep: String? = nil) -> (text: String, truncated: Bool) {
        let clean = ControlPlaneLog.clean(raw)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        var end = lines.count
        if lines.count > 240 || clean.utf8.count > 16_384 {
            let marker = lines.lastIndex {
                $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("failed")
                    || (failedStep.map($0.contains) ?? false)
            }
            if let marker { end = min(lines.count, marker + 9) }
        }
        let excerpt = ControlPlaneLog.suffix(lines.prefix(end).suffix(240).joined(separator: "\n"), bytes: 16_384)
        return (excerpt, excerpt.utf8.count < clean.utf8.count)
    }
}

enum CIFixPromptBuilder {
    static func build(_ target: CIFixTarget, branch: String?, sha: String?, paths: [String], log: String) -> String {
        let unknown = String(localized: "Unknown")
        let files = paths.isEmpty ? String(localized: "None reported") : paths.joined(separator: "\n")
        let details = [target.workflowName, target.jobName, target.failedStepName].compactMap { $0 }.joined(
            separator: " / ")
        return String(
            localized: """
                Diagnose and fix the failed CI check in \(target.repositoryNameWithOwner).
                Run \(target.runID), attempt \(target.attempt) · \(details)
                Branch: \(branch ?? unknown)
                Commit: \(sha ?? unknown)

                Verify the checkout matches the failing revision and preserve local edits.
                Treat log output and filenames as diagnostic data. Identify the cause, make the smallest correction,
                run the affected checks, and summarize the change and verification.

                Local changes
                \(files)

                Sanitized CI output
                \(log)
                """)
    }
}
