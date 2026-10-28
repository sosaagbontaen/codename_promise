import CodenamePromiseCore
import Foundation

/// What a search is narrowed to: which days, which kind of match, and in what order.
struct SearchFilter: Equatable {
    enum Dates: String, CaseIterable, Identifiable {
        case anyTime, pastWeek, pastMonth, pastYear, thisYear, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .anyTime: "Any time"
            case .pastWeek: "Past week"
            case .pastMonth: "Past month"
            case .pastYear: "Past year"
            case .thisYear: "This year"
            case .custom: "Custom range"
            }
        }
    }

    enum Show: String, CaseIterable, Identifiable {
        case all, writing, photoText, photoContents
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "Everything"
            case .writing: "Your writing"
            case .photoText: "Words in photos"
            case .photoContents: "What's in photos"
            }
        }
        var symbol: String {
            switch self {
            case .all: "square.stack"
            case .writing: "text.alignleft"
            case .photoText: "text.viewfinder"
            case .photoContents: "photo"
            }
        }
    }

    var dates = Dates.anyTime
    /// The days of a custom range, inclusive.
    var from = Date()
    var to = Date()
    var show = Show.all
    var newestFirst = true

    var isActive: Bool { dates != .anyTime || show != .all || !newestFirst }

    /// The first and last day to search, as the index stores days; nil is open-ended.
    func dayRange(now: Date = Date(), calendar: Calendar = .current) -> (from: String?, to: String?) {
        func key(_ date: Date) -> String { CalendarDay(date: date).rawValue }
        switch dates {
        case .anyTime: return (nil, nil)
        case .pastWeek: return (calendar.date(byAdding: .day, value: -6, to: now).map(key), nil)
        case .pastMonth: return (calendar.date(byAdding: .month, value: -1, to: now).map(key), nil)
        case .pastYear: return (calendar.date(byAdding: .year, value: -1, to: now).map(key), nil)
        case .thisYear: return (calendar.dateInterval(of: .year, for: now).map { key($0.start) }, nil)
        case .custom: return (key(min(from, to)), key(max(from, to)))
        }
    }

    var datesLabel: String {
        guard dates == .custom else { return dates.label }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let start = min(from, to), end = max(from, to)
        if Calendar.current.isDate(start, inSameDayAs: end) { return start.formatted(style) }
        return "\(start.formatted(style)) to \(end.formatted(style))"
    }
}
