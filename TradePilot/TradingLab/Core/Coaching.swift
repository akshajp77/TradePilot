import Foundation

// Coaching that happens inside the trading flow. Everything here is written for beginners:
// short sentences, no jargon without an explanation, and never "buy this" or "sell that".

// MARK: - Pre-trade check

nonisolated struct CoachNote: Identifiable, Hashable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case tip = 0, caution = 1, warning = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    let id: String
    let level: Level
    let title: String
    let detail: String
    /// Path lesson that explains this, when there is one.
    var lessonID: String?
}

nonisolated struct PreTradeInputs: Sendable {
    var request: OrderRequest
    /// Price the order is expected to fill near.
    var entry: Decimal?
    var equity: Decimal?
    var currentShares: Decimal = 0
    var bid: Decimal?
    var ask: Decimal?
    /// Average daily share volume, if known.
    var averageVolume: Double?
    var nextEarnings: Date?
    /// 50-day average of daily closes and the last close, for the big-picture trend.
    var sma50: Double?
    var lastClose: Double?
    /// When the most recent losing trade closed.
    var lastLossAt: Date?
    var entriesLast30Minutes = 0
    var consecutiveLosses = 0
    var now = Date()
}

nonisolated enum PreTradeCheck {
    static func notes(_ i: PreTradeInputs) -> [CoachNote] {
        var notes: [CoachNote] = []
        let r = i.request
        let opening = r.role == .entry && !r.reduceOnly && (r.side == .buy ? i.currentShares >= 0 : i.currentShares <= 0)
        guard opening else { return [] }
        let stop = r.stopLoss ?? r.plannedStop

        if stop == nil && !r.type.isStopFamily {
            notes.append(CoachNote(id: "no-stop", level: .warning, title: "No stop loss",
                                   detail: "Nothing will get you out if the price moves against you. Decide now where you'd admit you're wrong, and add a stop loss there.",
                                   lessonID: "u2-stop-loss"))
        }
        if let stop, let entry = i.entry, let equity = i.equity, equity > 0 {
            let risk = abs(entry - stop) * r.shares
            let fraction = (risk / equity).double
            if fraction > 0.02 {
                notes.append(CoachNote(id: "big-risk", level: .warning, title: "You'd risk \(Format.percent(fraction, digits: 1).dropFirst()) of your account",
                                       detail: "If your stop is hit you lose \(Format.money(risk.rounded(Precision.cash))). Most traders keep this to 1–2% so a losing streak can't sink them. Try fewer shares.",
                                       lessonID: "u2-position-size"))
            }
        } else if let entry = i.entry, let equity = i.equity, equity > 0 {
            let fraction = (entry * r.shares / equity).double
            if fraction > 0.25 {
                notes.append(CoachNote(id: "big-position", level: .caution, title: "This is \(Int(fraction * 100))% of your account",
                                       detail: "One stock this big can swing your whole account. Smaller positions make mistakes cheaper while you learn.",
                                       lessonID: "u2-position-size"))
            }
        }
        if let earnings = i.nextEarnings {
            let hours = earnings.timeIntervalSince(i.now) / 3600
            if hours >= -12 && hours <= 36 {
                notes.append(CoachNote(id: "earnings", level: .caution, title: "Earnings report \(hours < 12 ? "today" : "tomorrow")",
                                       detail: "Companies report their results then, and the price can jump or drop a lot in seconds, even past your stop loss.",
                                       lessonID: "u1-why-prices-move"))
            }
        }
        if let bid = i.bid, let ask = i.ask, bid > 0, ask > bid {
            let spread = ((ask - bid) / ((ask + bid) / 2)).double
            if spread > 0.005 {
                notes.append(CoachNote(id: "wide-spread", level: .caution, title: "Big gap between buy and sell prices",
                                       detail: "Buyers pay \(Format.money(ask)) but sellers only get \(Format.money(bid)). That gap (the spread) is a cost you pay right away. A limit order helps.",
                                       lessonID: "u1-bid-ask"))
            }
        }
        if let volume = i.averageVolume, volume < 500_000 {
            notes.append(CoachNote(id: "thin", level: .caution, title: "Not many shares trade each day",
                                   detail: "With few buyers and sellers, prices can jump and it can be hard to get out at a fair price.",
                                   lessonID: "u3-volume"))
        }
        if let sma = i.sma50, let last = i.lastClose, sma > 0 {
            let against = (r.side == .buy && last < sma * 0.97) || (r.side == .sell && last > sma * 1.03)
            if against {
                notes.append(CoachNote(id: "trend", level: .tip, title: r.side == .buy ? "The bigger trend is down" : "The bigger trend is up",
                                       detail: "Over the last 50 days the price has mostly been going \(r.side == .buy ? "down" : "up"). Trading against that is harder. Have a clear reason.",
                                       lessonID: "u3-trends"))
            }
        }
        if let lossAt = i.lastLossAt, i.now.timeIntervalSince(lossAt) < 180 {
            notes.append(CoachNote(id: "revenge", level: .warning, title: "Right after a loss",
                                   detail: "Jumping back in within minutes of a loss is called revenge trading. It's one of the most common ways people lose money. Take a breath first.",
                                   lessonID: "u2-emotions"))
        }
        if i.consecutiveLosses >= 3 {
            notes.append(CoachNote(id: "streak", level: .warning, title: "\(i.consecutiveLosses) losses in a row",
                                   detail: "Losing streaks happen to everyone, but they also make us take worse trades. A 15-minute break usually helps.",
                                   lessonID: "u2-emotions"))
        }
        if i.entriesLast30Minutes >= 8 {
            notes.append(CoachNote(id: "overtrading", level: .caution, title: "Lots of trades in a short time",
                                   detail: "That's \(i.entriesLast30Minutes) trades in 30 minutes. More trades means more costs and more rushed decisions.",
                                   lessonID: "u4-day-trading-reality"))
        }
        return notes.sorted { $0.level > $1.level }
    }
}

// MARK: - Tilt guard

nonisolated enum TiltGuard {
    /// Losses in a row among today's closed trades, newest first.
    static func consecutiveLosses(_ trips: [RoundTrip]) -> Int {
        let closed = trips.filter { !$0.isOpen }.sorted { ($0.exitTime ?? $0.entryTime) > ($1.exitTime ?? $1.entryTime) }
        var count = 0
        for trip in closed { if trip.netPnL < 0 { count += 1 } else { break } }
        return count
    }

    static func lastLoss(_ trips: [RoundTrip]) -> Date? {
        trips.filter { !$0.isOpen && $0.netPnL < 0 }.compactMap(\.exitTime).max()
    }

    static func entries(_ account: AccountData, within seconds: TimeInterval, now: Date) -> Int {
        account.orders.filter { $0.role == .entry && $0.status == .filled && now.timeIntervalSince($0.filledAt ?? .distantPast) < seconds }.count
    }

    /// Suggests a cool-down after three straight losses.
    static func shouldSuggestBreak(_ todaysTrips: [RoundTrip]) -> Bool { consecutiveLosses(todaysTrips) >= 3 }
}

// MARK: - Post-trade review

nonisolated struct TradeReview: Sendable, Equatable {
    struct Item: Hashable, Sendable { let passed: Bool; let text: String }
    let score: Int
    let grade: String
    let items: [Item]
    /// The one-line lesson for this trade.
    let headline: String

    static func grade(_ score: Int) -> String {
        switch score { case 85...: return "A"; case 70..<85: return "B"; case 55..<70: return "C"; case 40..<55: return "D"; default: return "F" }
    }

    /// Grades how the trade was made, not whether it made money.
    static func review(_ trip: RoundTrip, entry: PracticeOrder?, note: TradeNote?, equity: Decimal) -> TradeReview {
        var score = 0
        var items: [Item] = []
        if let stop = trip.plannedStop {
            score += 25
            items.append(Item(passed: true, text: "You had a stop loss at \(Format.money(stop))."))
            let plannedRisk = abs(trip.averageEntry - stop) * trip.quantity
            if trip.netPnL < 0 {
                let kept = -trip.netPnL <= plannedRisk * Decimal(string: "1.1")! + trip.fees
                score += kept ? 25 : 0
                items.append(Item(passed: kept, text: kept ? "Your loss stayed within what you planned to risk."
                                  : "You lost more than you planned (\(Format.money(-trip.netPnL)) vs \(Format.money(plannedRisk.rounded(Precision.cash)))). Did the stop move, or did the price jump past it?"))
            } else {
                score += 25
            }
            if equity > 0 {
                let fraction = (plannedRisk / equity).double
                let ok = fraction <= 0.02
                score += ok ? 20 : 5
                items.append(Item(passed: ok, text: ok ? "You risked \(Format.percent(fraction, digits: 1).dropFirst()) of your account. Sensible size."
                                  : "You risked \(Format.percent(fraction, digits: 1).dropFirst()) of your account. Aim for 2% or less."))
            }
        } else {
            items.append(Item(passed: false, text: "No stop loss. Without one, a small loss can turn into a big one."))
            score += trip.netPnL < 0 ? 0 : 10
        }
        switch note?.followedPlan {
        case true?: score += 15; items.append(Item(passed: true, text: "You followed your plan."))
        case false?: items.append(Item(passed: false, text: "You said you didn't follow your plan. What pulled you off it?"))
        case nil: score += 7
        }
        if let entry, !entry.thesis.isEmpty {
            score += 15
            items.append(Item(passed: true, text: "You wrote down why you took the trade."))
        } else {
            items.append(Item(passed: false, text: "No reason written down. One sentence before each trade makes reviewing much easier."))
        }
        score = min(100, score)
        let letter = grade(score)
        let headline: String
        switch (score >= 70, trip.netPnL >= 0) {
        case (true, false): headline = "Good process, bad result. That's okay: even well-made trades lose sometimes. Keep doing this."
        case (true, true): headline = "Good process and a good result. This is the kind of trade to repeat."
        case (false, true): headline = "You made money, but the process was shaky. Lucky wins can build bad habits."
        case (false, false): headline = "This one broke some rules. Look at the red items below and pick one to fix next time."
        }
        return TradeReview(score: score, grade: letter, items: items, headline: headline)
    }
}

// MARK: - Weekly report card

nonisolated struct WeeklyReport: Sendable {
    var trades = 0
    var netPnL: Decimal = 0
    var winRate: Double?
    var stopUsage: Double?
    var averageScore: Int?
    var busiestDay: (date: Date, trades: Int)?
    var worstHour: (hour: Int, pnl: Decimal)?
    var bestSetup: (name: String, pnl: Decimal)?
    var worstSetup: (name: String, pnl: Decimal)?
    var losersHeldLonger = false
    var fix: String = ""
    var praise: String?
    /// Days in a row (most recent first) where every closed trade had a stop and scored C or better.
    var processStreak = 0

    static func build(trips allTrips: [RoundTrip], account: AccountData, notes: [String: TradeNote],
                      equity: Decimal, now: Date = Date(), hours: MarketHours = .nyse) -> WeeklyReport {
        var report = WeeklyReport()
        let start = now.addingTimeInterval(-7 * 86_400)
        let closed = allTrips.filter { !$0.isOpen }
        let week = closed.filter { ($0.exitTime ?? $0.entryTime) >= start }
        let stats = TradeAnalytics.stats(week)
        report.trades = stats.trades
        report.netPnL = stats.netPnL
        report.winRate = stats.winRate
        let ordersByID = Dictionary(account.orders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func score(_ trip: RoundTrip) -> Int {
            TradeReview.review(trip, entry: ordersByID[trip.id], note: notes[trip.id.uuidString], equity: equity).score
        }
        if !week.isEmpty {
            report.stopUsage = Double(week.filter { $0.plannedStop != nil }.count) / Double(week.count)
            report.averageScore = week.map(score).reduce(0, +) / week.count
            let byDay = Dictionary(grouping: week) { hours.dayStart($0.entryTime) }
            if let busiest = byDay.max(by: { $0.value.count < $1.value.count }) { report.busiestDay = (busiest.key, busiest.value.count) }
            let byHour = Dictionary(grouping: week) { hours.calendar.component(.hour, from: $0.entryTime) }
                .mapValues { $0.reduce(Decimal(0)) { $0 + $1.netPnL } }
            if let worst = byHour.min(by: { $0.value < $1.value }), worst.value < 0 { report.worstHour = (worst.key, worst.value) }
            let bySetup = Dictionary(grouping: week, by: \.setup).mapValues { $0.reduce(Decimal(0)) { $0 + $1.netPnL } }
            if let best = bySetup.max(by: { $0.value < $1.value }), best.value > 0 { report.bestSetup = (best.key, best.value) }
            if let worst = bySetup.min(by: { $0.value < $1.value }), worst.value < 0 { report.worstSetup = (worst.key, worst.value) }
            if let win = stats.averageHoldWin, let loss = stats.averageHoldLoss { report.losersHeldLonger = loss > win * 1.5 }
        }
        // Streak over all history, newest day first.
        let days = Dictionary(grouping: closed) { hours.dayStart($0.exitTime ?? $0.entryTime) }
        for day in days.keys.sorted(by: >) {
            let trips = days[day] ?? []
            if trips.allSatisfy({ $0.plannedStop != nil && score($0) >= 55 }) { report.processStreak += 1 } else { break }
        }
        // One fix, most important first.
        if week.isEmpty {
            report.fix = "No trades closed this week. Try one practice trade with a stop loss and a written reason."
        } else if (report.stopUsage ?? 1) < 0.8 {
            report.fix = "Put a stop loss on every trade. Only \(Int((report.stopUsage ?? 0) * 100))% of your trades had one this week."
        } else if let busiest = report.busiestDay, busiest.trades > 10 {
            report.fix = "Set a limit of 5 trades a day. You made \(busiest.trades) on your busiest day, and rushed trades are usually worse."
        } else if report.losersHeldLonger {
            report.fix = "Cut losing trades sooner. You held losers much longer than winners, which usually means hoping instead of following the plan."
        } else if let worst = report.worstHour, worst.pnl < -abs(report.netPnL) / 2 || report.netPnL < 0 {
            report.fix = "Skip trading around \(worst.hour):00 ET for a week. That hour cost you \(Format.money(-worst.pnl))."
        } else if let setup = report.worstSetup {
            report.fix = "Pause the \"\(setup.name)\" setup. It lost \(Format.money(-setup.pnl)) this week. Review those trades before trying it again."
        } else {
            report.fix = "Keep doing what you're doing, and keep writing a reason for every trade."
        }
        if (report.stopUsage ?? 0) >= 0.9 { report.praise = "You used a stop loss on almost every trade. That's the most important habit there is." }
        else if (report.averageScore ?? 0) >= 75 { report.praise = "Your trades were well planned this week." }
        return report
    }
}

// MARK: - Real-money readiness

nonisolated struct ReadinessItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let progress: Double
    var met: Bool { progress >= 1 }
    /// Age can't be overridden.
    var required = false
}

nonisolated enum Readiness {
    static let tradesNeeded = 50
    static let weeksNeeded = 8
    static let requiredUnits = ["u1", "u2", "u5"]

    static func items(trips: [RoundTrip], learning: LearningState, units: [PathUnit], now: Date = Date()) -> [ReadinessItem] {
        let closed = trips.filter { !$0.isOpen }
        var items: [ReadinessItem] = []
        let adult = learning.profile?.isAdult(now: now) ?? false
        items.append(ReadinessItem(id: "age", title: "18 or older",
                                   detail: adult ? "Brokerages require account holders to be adults." : "Real brokerage accounts are for adults. Until then, keep practicing here, or ask a parent about a custodial account they control.",
                                   progress: adult ? 1 : 0, required: true))
        items.append(ReadinessItem(id: "trades", title: "\(tradesNeeded) practice trades",
                                   detail: "\(closed.count) of \(tradesNeeded) closed. Enough trades to know your results aren't just luck.",
                                   progress: min(1, Double(closed.count) / Double(tradesNeeded))))
        let first = closed.map(\.entryTime).min()
        let weeks = first.map { now.timeIntervalSince($0) / (7 * 86_400) } ?? 0
        items.append(ReadinessItem(id: "weeks", title: "\(weeksNeeded) weeks of practice",
                                   detail: "\(Int(weeks)) of \(weeksNeeded) weeks. Markets change; practice through different kinds of weeks.",
                                   progress: min(1, weeks / Double(weeksNeeded))))
        let recent = closed.filter { ($0.exitTime ?? $0.entryTime) >= now.addingTimeInterval(-Double(weeksNeeded) * 7 * 86_400) }
        let net = recent.reduce(Decimal(0)) { $0 + $1.netPnL }
        let profitable = recent.count >= 20 && net > 0
        items.append(ReadinessItem(id: "profit", title: "Profitable over the last \(weeksNeeded) weeks",
                                   detail: recent.count < 20 ? "Needs at least 20 trades in that time (\(recent.count) so far)." : "\(Format.signedMoney(net)) after costs over \(recent.count) trades.",
                                   progress: profitable ? 1 : recent.count < 20 ? Double(recent.count) / 40 : 0.5))
        let last = Array(closed.sorted { $0.entryTime > $1.entryTime }.prefix(tradesNeeded))
        let stopRate = last.isEmpty ? 0 : Double(last.filter { $0.plannedStop != nil }.count) / Double(last.count)
        items.append(ReadinessItem(id: "stops", title: "Stop loss on 90% of trades",
                                   detail: "\(Int(stopRate * 100))% of your last \(last.count) trades had one.",
                                   progress: min(1, stopRate / 0.9)))
        let lessons = units.filter { requiredUnits.contains($0.id) }.flatMap(\.lessons)
        let done = lessons.filter { learning.isComplete($0.id) }.count
        items.append(ReadinessItem(id: "lessons", title: "Basics, risk and safety lessons",
                                   detail: "\(done) of \(lessons.count) lessons in units 1, 2 and 5.",
                                   progress: lessons.isEmpty ? 1 : Double(done) / Double(lessons.count)))
        return items
    }

    static func isReady(_ items: [ReadinessItem]) -> Bool { items.allSatisfy(\.met) }
    /// Adults can choose to skip the practice requirements after acknowledging the risk.
    static func canOverride(_ items: [ReadinessItem]) -> Bool { items.filter(\.required).allSatisfy(\.met) }
}
