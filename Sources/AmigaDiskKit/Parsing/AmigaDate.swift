import Foundation

/// AmigaOS datestamp: days since 1978-01-01, minutes past midnight,
/// ticks (1/50 s) past the minute. Used by FFS root/dir blocks and the
/// PFS3 rootblock / direntries.
public struct AmigaDate {
    public let days: UInt32
    public let minutes: UInt32
    public let ticks: UInt32

    public static let epoch: TimeInterval = 252_460_800  // 1978-01-01 00:00:00 UTC

    public init(days: UInt32, minutes: UInt32, ticks: UInt32) {
        self.days = days
        self.minutes = minutes
        self.ticks = ticks
    }

    public init(date: Date) {
        let secondsSinceAmigaEpoch = max(0, date.timeIntervalSince1970 - AmigaDate.epoch)
        // Ticks are 1/50 s — keep sub-second resolution so arbitrary on-disk
        // datestamps (e.g. from golden fixtures) are representable.
        let totalTicks = Int((secondsSinceAmigaEpoch * 50).rounded())
        days = UInt32(totalTicks / (86400 * 50))
        minutes = UInt32((totalTicks % (86400 * 50)) / (60 * 50))
        ticks = UInt32(totalTicks % (60 * 50))
    }

    /// The exact `Date` this datestamp represents.
    public var date: Date {
        Date(timeIntervalSince1970: AmigaDate.epoch
             + Double(days) * 86400 + Double(minutes) * 60 + Double(ticks) / 50)
    }
}
