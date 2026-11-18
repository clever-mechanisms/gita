import Foundation
import os

/// Vercel's public status, shared by every open repository so one read serves them all. A failed read is
/// remembered only briefly, so one transient failure does not blank the status everywhere.
final class VercelPlatformCache: Sendable {
    enum Lookup: Sendable, Equatable {
        case miss
        /// A cached read; nil when that read failed.
        case hit(VercelSignals.Platform?)
    }

    static let shared = VercelPlatformCache()
    static let failureLifetime: TimeInterval = 60

    private let entry = OSAllocatedUnfairLock<(at: Date, platform: VercelSignals.Platform?)?>(initialState: nil)

    func lookup(maxAge: TimeInterval, now: Date) -> Lookup {
        entry.withLock { entry in
            guard let entry else { return .miss }
            let age = now.timeIntervalSince(entry.at)
            let lifetime = entry.platform == nil ? min(maxAge, Self.failureLifetime) : maxAge
            return age >= 0 && age < lifetime ? .hit(entry.platform) : .miss
        }
    }

    func store(_ platform: VercelSignals.Platform?, now: Date) {
        entry.withLock { $0 = (now, platform) }
    }
}
