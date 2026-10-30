import Foundation

nonisolated enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1H", day = "1D", week = "1W", month = "1M"
    case quarter = "3M", yearToDate = "YTD", year = "1Y", fiveYears = "5Y"
    var id: String { rawValue }

    var request: (range: String, interval: String) {
        switch self {
        case .hour, .day: return ("1d", "1m")
        case .week: return ("5d", "30m")
        case .month: return ("1mo", "1d")
        case .quarter: return ("3mo", "1d")
        case .yearToDate: return ("ytd", "1d")
        case .year: return ("1y", "1d")
        case .fiveYears: return ("5y", "1wk")
        }
    }

    var isIntraday: Bool { self == .hour || self == .day }

    func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .hour: return now.addingTimeInterval(-3600)
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .month: return calendar.date(byAdding: .month, value: -1, to: now) ?? .distantPast
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now) ?? .distantPast
        case .yearToDate: return calendar.date(from: calendar.dateComponents([.year], from: now)) ?? .distantPast
        case .year: return calendar.date(byAdding: .year, value: -1, to: now) ?? .distantPast
        case .fiveYears: return calendar.date(byAdding: .year, value: -5, to: now) ?? .distantPast
        }
    }
}
