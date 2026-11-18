import Darwin
import Foundation

/// A new directory only this user can enter (`mkdtemp`, mode 0700), for inputs that must not race other writers.
enum PrivateTemporaryDirectory {
    static func make(prefix: String, failure: @autoclosure () -> any Error) throws -> URL {
        var template = Array(
            FileManager.default.temporaryDirectory.appendingPathComponent(prefix + "-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else { throw failure() }
        return URL(fileURLWithPath: String(cString: created), isDirectory: true)
    }
}
