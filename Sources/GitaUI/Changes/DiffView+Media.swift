import AppKit
import GitaCore

/// Result of asynchronously loading and decoding both sides of a binary image diff.
struct ImageDiffLoadResult: Sendable {
    var old: ImageDiffAsset?
    var new: ImageDiffAsset?
    var oldByteCount: Int64?
    var newByteCount: Int64?
}

/// Loads binary image bytes from Git or disk and decodes them off the main thread.
enum ImageDiffLoader {
    static func loadDiff(service: GitService, diffText: String, fileURL: URL?) async -> ImageDiffLoadResult {
        let payload = await service.binaryDiffData(
            in: diffText, fileURL: fileURL, maxBytes: ImageDiffAsset.maxPreviewBytes)
        let decoded = await decodePair(oldData: payload.oldData, newData: payload.newData)
        return ImageDiffLoadResult(
            old: decoded.old, new: decoded.new,
            oldByteCount: payload.oldByteCount, newByteCount: payload.newByteCount)
    }

    static func loadBlob(service: GitService, commit: String, path: String) async -> ImageDiffAsset? {
        guard
            let data = try? await service.fileData(
                commit: commit, path: path, maxBytes: ImageDiffAsset.maxPreviewBytes)
        else { return nil }
        return await decodeSingle(data)
    }

    private static func decodePair(
        oldData: Data?, newData: Data?
    ) async -> (old: ImageDiffAsset?, new: ImageDiffAsset?) {
        let task = Task.detached(priority: .userInitiated) {
            (oldData.flatMap(ImageDiffAsset.decode), newData.flatMap(ImageDiffAsset.decode))
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func decodeSingle(_ data: Data) async -> ImageDiffAsset? {
        let task = Task.detached(priority: .userInitiated) {
            ImageDiffAsset.decode(data: data)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Binary and image diff presentation helpers for `DiffView`.
extension DiffView {
    func showBinaryOrImageIfNeeded(
        text: String, path: String?, blob: Bool, binaryBlobByteCount: Int64?
    ) -> Bool {
        guard
            let binary = BinaryDiffSummary.resolve(
                .init(
                    text: text, path: path, isBlob: blob, binaryBlobByteCount: binaryBlobByteCount,
                    fileURL: existingFileURL(for: path)))
        else {
            imageDiffView.apply(.hidden)
            binaryEmptyView.show(nil)
            onMediaDisplayChanged?(false)
            return false
        }
        clearRowsForBinary()
        if ImageFileFormat.isSupportedImagePath(path) {
            binaryEmptyView.show(nil)
            imageDiffView.apply(.loading(binary))
            onMediaDisplayChanged?(true)
        } else {
            imageDiffView.apply(.hidden)
            binaryEmptyView.show(binary)
            onMediaDisplayChanged?(false)
        }
        rerunFindIfOpen()
        return true
    }

    func needsImageLoad(for path: String) -> Bool {
        shownPath == path && imageDiffView.state.isLoading(path: path)
    }

    func updateBinarySizes(old: Int64?, new: Int64?, for path: String) {
        guard shownPath == path else { return }
        if var summary = binaryEmptyView.summary {
            if let old { summary.oldByteCount = old }
            if let new { summary.newByteCount = new }
            binaryEmptyView.show(summary)
            return
        }
        if case .loading(var summary) = imageDiffView.state {
            if let old { summary.oldByteCount = old }
            if let new { summary.newByteCount = new }
            imageDiffView.apply(.loading(summary))
        }
    }

    func updateImageDiff(old: ImageDiffAsset?, new: ImageDiffAsset?, for path: String, isBlob: Bool) {
        guard shownPath == path, var summary = imageDiffView.state.summary ?? binaryEmptyView.summary else { return }
        if let oldBytes = old?.byteCount { summary.oldByteCount = oldBytes }
        if let newBytes = new?.byteCount { summary.newByteCount = newBytes }
        guard old != nil || new != nil else {
            fallbackToBinaryEmpty(for: path)
            return
        }
        binaryEmptyView.show(nil)
        imageDiffView.apply(.ready(ImageDiffDocument(summary: summary, old: old, new: new, isBlob: isBlob)))
        onMediaDisplayChanged?(true)
    }

    func fallbackToBinaryEmpty(for path: String) {
        guard shownPath == path, let summary = imageDiffView.state.summary else { return }
        imageDiffView.apply(.hidden)
        binaryEmptyView.show(summary)
        onMediaDisplayChanged?(false)
    }

    func existingFileURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty, let root = repositoryRoot else { return nil }
        let url = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
