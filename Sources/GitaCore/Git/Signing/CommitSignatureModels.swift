import Foundation

/// Git commit signature verification status reported by `%G?`.
public enum CommitSignatureStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case valid
    case bad
    case unknownValidity
    case expired
    case expiredKey
    case revokedKey
    case cannotCheck
    case none

    /// High-level visual category for compact signature badges.
    public enum BadgeCategory: Sendable, Equatable, Hashable {
        case verified
        case unverified
        case invalid
        case unsigned
    }

    public init(gitCode: String) {
        switch gitCode.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "G":
            self = .valid
        case "B":
            self = .bad
        case "U":
            self = .unknownValidity
        case "X":
            self = .expired
        case "Y":
            self = .expiredKey
        case "R":
            self = .revokedKey
        case "E":
            self = .cannotCheck
        default:
            self = .none
        }
    }

    public var isSigned: Bool { self != .none }

    public var badgeCategory: BadgeCategory {
        switch self {
        case .valid:
            return .verified
        case .bad, .revokedKey:
            return .invalid
        case .unknownValidity, .expired, .expiredKey, .cannotCheck:
            return .unverified
        case .none:
            return .unsigned
        }
    }

    public var badgeTitle: String {
        switch badgeCategory {
        case .verified:
            return String(localized: "Verified")
        case .unverified:
            return String(localized: "Unverified")
        case .invalid:
            return String(localized: "Invalid")
        case .unsigned:
            return String(localized: "Unsigned")
        }
    }

    public var statusDescription: String {
        switch self {
        case .valid:
            return String(localized: "Good signature verified by Git.")
        case .bad:
            return String(localized: "Bad signature. Commit integrity could not be confirmed.")
        case .unknownValidity:
            return String(localized: "Good signature with unknown key trust.")
        case .expired:
            return String(localized: "Good signature that has expired.")
        case .expiredKey:
            return String(localized: "Signed by a key that has expired.")
        case .revokedKey:
            return String(localized: "Signed by a revoked key.")
        case .cannotCheck:
            return String(localized: "Signature could not be checked because the signing key is unavailable.")
        case .none:
            return String(localized: "This commit is not signed.")
        }
    }
}

/// Signature metadata parsed from a single commit.
public struct CommitSignatureInfo: Sendable, Equatable, Hashable {
    public static let unsigned = Self(status: .none, signer: nil, keyID: nil, fingerprint: nil)

    public let status: CommitSignatureStatus
    public let signer: String?
    public let keyID: String?
    public let fingerprint: String?

    public init(status: CommitSignatureStatus, signer: String?, keyID: String?, fingerprint: String?) {
        self.status = status
        self.signer = Self.nonEmpty(signer)
        self.keyID = Self.nonEmpty(keyID)
        self.fingerprint = Self.nonEmpty(fingerprint)
    }

    public var isSigned: Bool { status.isSigned }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Git signing key format (`gpg.format`).
public enum CommitSigningFormat: String, Sendable, Equatable, Hashable, CaseIterable {
    case openpgp
    case ssh
    case x509

    public init(gitConfigValue: String?) {
        let normalized = gitConfigValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = Self(rawValue: normalized) ?? .openpgp
    }

    public var displayName: String {
        switch self {
        case .openpgp:
            return String(localized: "GPG")
        case .ssh:
            return String(localized: "SSH")
        case .x509:
            return String(localized: "X.509")
        }
    }
}

/// Effective and repo-local commit signing configuration for a repository.
public struct CommitSigningConfig: Sendable, Equatable, Hashable {
    public let isEnabled: Bool
    public let isRepoLocalOverride: Bool
    public let format: CommitSigningFormat
    public let signingKey: String?

    public init(isEnabled: Bool, isRepoLocalOverride: Bool, format: CommitSigningFormat, signingKey: String?) {
        self.isEnabled = isEnabled
        self.isRepoLocalOverride = isRepoLocalOverride
        self.format = format
        let trimmed = signingKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.signingKey = trimmed?.isEmpty == true ? nil : trimmed
    }

    public var isConfigured: Bool { signingKey != nil }

    public var shortKeyDisplay: String? {
        guard let signingKey else { return nil }
        if signingKey.hasPrefix("ssh-") || signingKey.hasPrefix("key::") {
            let parts = signingKey.split(separator: " ")
            if parts.count >= 3 { return String(parts[2]) }
            return String(signingKey.suffix(16))
        }
        if signingKey.contains("/") {
            return URL(fileURLWithPath: signingKey).lastPathComponent
        }
        return signingKey.count > 16 ? String(signingKey.suffix(16)) : signingKey
    }
}
