import Foundation

/// NYSE sessions with the exchange-published 2026–2028 holidays and 1 p.m. early closes.
/// Regular session 9:30–16:00 ET; pre-market from 4:00; after-hours until 20:00 (17:00 on early-close days).
/// Past 2028 only weekends are known; add the next calendar when NYSE publishes it.
nonisolated struct MarketHours: Sendable {
    static let nyse = MarketHours()

    enum Phase: Equatable, Sendable {
        case open(closesAt: Date)
        case preMarket(opensAt: Date)
        case afterHours(opensAt: Date)
        case closed(opensAt: Date)   // weekend, holiday or overnight
        var isOpen: Bool { if case .open = self { return true } else { return false } }
    }

    enum SessionKind: Sendable { case pre, regular, post, closed }

    struct Session: Sendable, Equatable {
        let preOpen: Date
        let open: Date
        let close: Date
        let postClose: Date
    }

    let timeZone = TimeZone(identifier: "America/New_York")!
    private let holidays: Set<String> = [
        "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19", "2026-07-03",
        "2026-09-07", "2026-11-26", "2026-12-25",
        "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18", "2027-07-05",
        "2027-09-06", "2027-11-25", "2027-12-24",
        "2028-01-17", "2028-02-21", "2028-04-14", "2028-05-29", "2028-06-19", "2028-07-04", "2028-09-04",
        "2028-11-23", "2028-12-25",
    ]
    private let earlyCloses: Set<String> = ["2026-11-27", "2026-12-24", "2027-11-26", "2028-07-03", "2028-11-24"]

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func key(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }

    /// All session times for the ET calendar day containing `date`, or nil if the exchange is closed that day.
    func fullSession(on date: Date) -> Session? {
        let cal = calendar
        let weekday = cal.component(.weekday, from: date)
        guard weekday != 1 && weekday != 7 else { return nil }
        let day = key(date)
        guard !holidays.contains(day) else { return nil }
        let start = cal.startOfDay(for: date)
        let closeHour = earlyCloses.contains(day) ? 13 : 16
        guard let pre = cal.date(bySettingHour: 4, minute: 0, second: 0, of: start),
              let open = cal.date(bySettingHour: 9, minute: 30, second: 0, of: start),
              let close = cal.date(bySettingHour: closeHour, minute: 0, second: 0, of: start),
              let post = cal.date(bySettingHour: closeHour + 4, minute: 0, second: 0, of: start) else { return nil }
        return Session(preOpen: pre, open: open, close: close, postClose: post)
    }

    /// Regular-session open and close for the ET calendar day containing `date`.
    func session(on date: Date) -> (open: Date, close: Date)? {
        fullSession(on: date).map { ($0.open, $0.close) }
    }

    func isOpen(at date: Date) -> Bool {
        guard let s = session(on: date) else { return false }
        return date >= s.open && date < s.close
    }

    /// True for prices printed during the regular session, closing print included.
    func isRegularSessionPrint(_ date: Date) -> Bool {
        guard let s = session(on: date) else { return false }
        return date >= s.open && date <= s.close
    }

    func sessionKind(at date: Date) -> SessionKind {
        guard let s = fullSession(on: date) else { return .closed }
        if date >= s.open && date <= s.close { return .regular }
        if date >= s.preOpen && date < s.open { return .pre }
        if date > s.close && date < s.postClose { return .post }
        return .closed
    }

    func isExtendedSessionPrint(_ date: Date) -> Bool {
        let kind = sessionKind(at: date)
        return kind == .pre || kind == .post
    }

    func nextOpen(after date: Date) -> Date {
        if let s = session(on: date), date < s.open { return s.open }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<15 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if let s = session(on: day) { return s.open }
        }
        return day
    }

    /// Open of the session containing or most recently before `date`.
    func latestSessionOpen(atOrBefore date: Date) -> Date? {
        if let s = session(on: date), date >= s.open { return s.open }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<15 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
            if let s = session(on: day) { return s.open }
        }
        return nil
    }

    /// The session (today's, or the next one) a day order placed at `date` belongs to.
    func targetSession(for date: Date, extendedHours: Bool) -> Session? {
        if let s = fullSession(on: date), date < (extendedHours ? s.postClose : s.close) { return s }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<15 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if let s = fullSession(on: day) { return s }
        }
        return nil
    }

    /// When a day order placed at `date` expires.
    func dayOrderExpiry(placedAt date: Date, extendedHours: Bool) -> Date? {
        targetSession(for: date, extendedHours: extendedHours).map { extendedHours ? $0.postClose : $0.close }
    }

    /// The most recent `count` session days ending at (and including) `date`'s day, newest first.
    func sessionDays(endingAt date: Date, count: Int) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: date)
        var guardrail = 0
        while result.count < count && guardrail < count * 3 + 10 {
            if session(on: day) != nil { result.append(day) }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
            guardrail += 1
        }
        return result
    }

    func phase(at date: Date) -> Phase {
        if let s = session(on: date) {
            if date < s.open { return .preMarket(opensAt: s.open) }
            if date < s.close { return .open(closesAt: s.close) }
            return .afterHours(opensAt: nextOpen(after: date))
        }
        return .closed(opensAt: nextOpen(after: date))
    }

    func isSameSessionDay(_ a: Date, _ b: Date) -> Bool { key(a) == key(b) }

    /// Start of the ET calendar day; a stable key for "session day".
    func dayStart(_ date: Date) -> Date { calendar.startOfDay(for: date) }
}
