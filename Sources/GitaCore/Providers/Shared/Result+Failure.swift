import Foundation

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
