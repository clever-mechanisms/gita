import Darwin
import Foundation

/// Low-level process table reads through libproc. No `ps`/`lsof` subprocesses; every call is a single syscall.
public enum AgentProcessTable {
    public struct Entry: Sendable, Hashable {
        public var parent: Int32
        /// Microseconds since 1970; distinguishes a reused pid from the process that had it before.
        public var start: UInt64
        public var hasTerminal: Bool
        public var terminalDevice: UInt32
    }

    private static let pathSize = 4 * Int(MAXPATHLEN)
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    public static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// Only the current user's processes; other users' rows are skipped, never read further.
    public static func entry(_ pid: Int32, uid: uid_t = getuid()) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { return nil }
        return Entry(
            parent: Int32(info.pbi_ppid), start: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec,
            hasTerminal: info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0, terminalDevice: info.e_tdev)
    }

    /// Parent, terminal and command name only, via the short BSD info (several times cheaper than `entry`); used for
    /// the whole table. The name is the executable's (up to 16 bytes) and changes when the process calls `exec`.
    public static func shortEntry(
        _ pid: Int32, uid: uid_t = getuid()
    ) -> (parent: Int32, hasTerminal: Bool, name: String)? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == uid else {
            return nil
        }
        let name = withUnsafeBytes(of: info.pbsi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (Int32(info.pbsi_ppid), info.pbsi_flags & UInt32(PROC_FLAG_CONTROLT) != 0, name)
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: pathSize)
        let length = proc_pidpath(pid, &buffer, UInt32(pathSize))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    /// Total user + system CPU in nanoseconds (task info reports Mach time units on Apple silicon).
    public static func cpuNanoseconds(_ pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
    }

    /// argv via `KERN_PROCARGS2`, bounded. Used only for interpreter processes (node/python) to find the script.
    public static func arguments(_ pid: Int32, limit: Int = 8) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        size = min(size, 256 * 1_024)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(buffer.prefix(size), limit: limit)
    }

    /// `KERN_PROCARGS2` layout: argc, the executable path, NUL padding, then argc NUL-terminated arguments.
    static func parseArguments(_ buffer: ArraySlice<UInt8>, limit: Int) -> [String] {
        let bytes = Array(buffer)
        guard bytes.count > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 } // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 } // padding
        var result: [String] = []
        while index < bytes.count, result.count < min(Int(argc), limit) {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    /// Parent chain nearest first, excluding `pid` itself and launchd; bounded.
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < limit, let entry = entry(current, uid: getuid()), entry.parent > 1,
            !chain.contains(entry.parent)
        {
            chain.append(entry.parent)
            current = entry.parent
        }
        return chain
    }
}
