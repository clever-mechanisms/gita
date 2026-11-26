import CoreServices
import Foundation

public struct ExternalToolDetector: Sendable {
    private let fileExists: @Sendable (String) -> Bool
    private let applicationURL: @Sendable (String) -> URL?

    public init(
        fileExists: @escaping @Sendable (String) -> Bool = {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        },
        applicationURL: @escaping @Sendable (String) -> URL? = {
            let urls = LSCopyApplicationURLsForBundleIdentifier($0 as CFString, nil)?.takeRetainedValue() as? [URL]
            return urls?.first
        }
    ) {
        self.fileExists = fileExists
        self.applicationURL = applicationURL
    }

    public func detect(_ preset: ExternalToolPreset) -> ExternalToolDetection {
        if let path = preset.cliPaths.first(where: fileExists) { return .installed(executablePath: path) }
        for identifier in preset.bundleIdentifiers {
            guard let bundle = applicationURL(identifier) else { continue }
            let path = bundle.appending(path: preset.embeddedCLI).path
            if fileExists(path) { return .installed(executablePath: path) }
        }
        return .notInstalled
    }

    public func detectAll() async -> [ExternalToolPreset: ExternalToolDetection] {
        let task = Task.detached(priority: .utility) {
            var found: [ExternalToolPreset: ExternalToolDetection] = [:]
            for preset in ExternalToolPreset.allCases where !Task.isCancelled {
                found[preset] = detect(preset)
            }
            return found
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
