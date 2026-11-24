import Foundation
import GitaCore

/// Single lifecycle enum for streaming file blame reads.
enum BlameLoad {
    case idle
    case loading(UUID, Task<Void, Never>)
    case loaded(BlameDocument)
    case failed(BlameError)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var document: BlameDocument? {
        if case .loaded(let document) = self { return document }
        return nil
    }

    var error: BlameError? {
        if case .failed(let error) = self { return error }
        return nil
    }

    mutating func cancel() {
        if case .loading(_, let task) = self { task.cancel() }
        self = .idle
    }
}
