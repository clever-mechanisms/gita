import Foundation

/// Token-shaped values never reach the screen, even from the user's own build output. Rules match real credential
/// formats so ordinary words such as `vercel_build_output` or `pkg-config-path` stay readable.
enum LogRedactor {
    private static let mask = "••••"

    private static let rules: [(pattern: String, template: String)] = [
        (
            #"(?i)\b([A-Z0-9_.-]*(SECRET|TOKEN|PASSWORD|PASSWD|API[_-]?KEY|PRIVATE[_-]?KEY|ACCESS[_-]?KEY)"#
                + #"[A-Z0-9_.-]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#,
            "$1$3" + mask
        ),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 " + mask),
        (#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#, mask),
        (#"\bgithub_pat_[A-Za-z0-9_]{22,}"#, mask),
        (#"\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{10,}"#, mask),
        (#"\bsk-[A-Za-z0-9_-]{20,}"#, mask),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, mask),
        (#"\bnpm_[A-Za-z0-9]{30,}"#, mask),
        (#"\bglpat-[A-Za-z0-9_-]{20,}"#, mask),
        (#"\bAKIA[0-9A-Z]{16}\b"#, mask),
        (#"\bvercel_[A-Za-z0-9]{20,}"#, mask),
        (#"\bpolar_[a-z]+_[A-Za-z0-9]{20,}"#, mask),
        (#"\b(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#, mask),
        (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1" + mask + "@"),
    ]

    static func redact(_ text: String) -> String {
        rules.reduce(text) { value, rule in
            value.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
    }
}
