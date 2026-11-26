import Foundation

public enum PatchExportSource: Equatable, Sendable {
    case workingTree, staged
    case commit(sha: String)
    case commitRange(from: String, to: String)
}

public struct PatchFileStat: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
}

public struct PatchPreview: Equatable, Sendable {
    public let patchURL: URL
    public let files: [PatchFileStat]
    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
    public let canApplyCleanly: Bool
    public let canApplyWithThreeWay: Bool
    public let diagnostic: String?
    let contentDigest: String
}

public struct PatchApplyOptions: Equatable, Sendable {
    public var threeWay: Bool
    public var index: Bool
    public init(threeWay: Bool = false, index: Bool = false) {
        self.threeWay = threeWay
        self.index = index
    }
}

public enum PatchApplyState: Equatable, Sendable {
    case idle, checking
    case ready(PatchPreview)
    case applying(PatchPreview)
    case applied(PatchPreview)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .checking, .applying: true
        default: false
        }
    }

    public var preview: PatchPreview? {
        switch self {
        case .ready(let preview), .applying(let preview), .applied(let preview): preview
        default: nil
        }
    }

    public func canApply(threeWay: Bool) -> Bool {
        guard case .ready(let preview) = self else { return false }
        return threeWay ? preview.canApplyWithThreeWay : preview.canApplyCleanly
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum PatchError: Error, LocalizedError, Equatable, Sendable {
    case emptyPatch, invalidFile, fileTooLarge, invalidStats, changedSincePreview

    public var errorDescription: String? {
        switch self {
        case .changedSincePreview: String(localized: "The patch changed. Check it again before applying.")
        case .emptyPatch: String(localized: "There are no changes to export.")
        case .invalidFile: String(localized: "Choose a readable local patch file.")
        case .fileTooLarge: String(localized: "Choose a patch of 32 MiB or less.")
        case .invalidStats: String(localized: "Git returned unreadable patch statistics.")
        }
    }
}
