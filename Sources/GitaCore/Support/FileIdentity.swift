import Darwin
import Foundation

/// The stat fields that identify one file version: device, inode, type and birth time, plus (by default) size,
/// modification and status-change times. Any write changes the status-change time, so equal identities mean the
/// content was not replaced or edited in between.
enum FileIdentity {
    static func of(_ info: stat, includeModification: Bool = true) -> String {
        let stable = [
            "\(info.st_dev)", "\(info.st_ino)", "\(info.st_mode)", "\(info.st_birthtimespec.tv_sec)",
            "\(info.st_birthtimespec.tv_nsec)",
        ]
        guard includeModification else { return stable.joined(separator: ":") }
        let changing = [
            "\(info.st_size)", "\(info.st_mtimespec.tv_sec)", "\(info.st_mtimespec.tv_nsec)",
            "\(info.st_ctimespec.tv_sec)", "\(info.st_ctimespec.tv_nsec)",
        ]
        return (stable + changing).joined(separator: ":")
    }
}
