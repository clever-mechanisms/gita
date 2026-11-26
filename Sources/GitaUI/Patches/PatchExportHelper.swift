import AppKit
import GitaCore
import UniformTypeIdentifiers

@MainActor
struct PatchExportHelper {
    enum Outcome: Equatable {
        case saved(URL, message: String)
        case cancelled
        case failed(String)
    }
    var destination: (String) -> URL? = { name in
        let panel = NSSavePanel()
        if let patch = UTType(filenameExtension: "patch") { panel.allowedContentTypes = [patch] }
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
    var write: @Sendable (Data, URL) async throws -> Void = { data, url in try data.write(to: url, options: .atomic) }

    func filename(for source: PatchExportSource) -> String {
        func stem(_ ref: String) -> String {
            let value = ref.components(
                separatedBy: CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "-_")
                ).inverted
            ).joined(separator: "-")
            return String(value.prefix(40))
        }
        switch source {
        case .workingTree: return "working-tree.patch"
        case .staged: return "staged.patch"
        case .commit(let sha): return stem(sha) + ".patch"
        case .commitRange(let from, let to): return stem(from) + ".." + stem(to) + ".patch"
        }
    }

    func export(_ source: PatchExportSource, service: GitService) async -> Outcome {
        await export(source, read: { try await service.exportPatch($0) })
    }

    func export(_ source: PatchExportSource, read: (PatchExportSource) async throws -> Data) async -> Outcome {
        guard let url = destination(filename(for: source)) else { return .cancelled }
        do {
            let data = try await read(source)
            try Task.checkCancellation()
            try await write(data, url)
            return .saved(url, message: String(localized: "Saved \(url.lastPathComponent)."))
        } catch is CancellationError { return .cancelled } catch { return .failed(error.localizedDescription) }
    }
}
