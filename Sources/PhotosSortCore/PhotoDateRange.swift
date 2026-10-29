import Foundation

/// A date-only review range represented as a half-open interval in the user's calendar.
public struct PhotoDateRange: Equatable, Sendable {
    public let startInclusive: Date
    public let endExclusive: Date

    public init(from: Date, through: Date, calendar: Calendar = .current) {
        let firstDay = calendar.startOfDay(for: min(from, through))
        let lastDay = calendar.startOfDay(for: max(from, through))
        startInclusive = firstDay
        endExclusive = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? .distantFuture
    }

    public func contains(_ date: Date) -> Bool {
        date >= startInclusive && date < endExclusive
    }
}
