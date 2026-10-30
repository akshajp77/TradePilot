import Foundation

/// One trade from flat to flat (or to a flip), built from fills.
nonisolated struct RoundTrip: Identifiable, Hashable, Sendable {
    let id: UUID              // first fill's order ID
    let symbol: String
    let isLong: Bool
    let entryTime: Date
    let exitTime: Date?
    let quantity: Decimal     // largest size held
    let averageEntry: Decimal
    let averageExit: Decimal?
    let grossPnL: Decimal
    let fees: Decimal
    let fillIDs: [UUID]
    let plannedStop: Decimal?
    let setup: String
    let isOpen: Bool

    var netPnL: Decimal { grossPnL - fees }
    var isWin: Bool { netPnL > 0 }
    var holdTime: TimeInterval? { exitTime.map { $0.timeIntervalSince(entryTime) } }
    /// Net P&L in units of initial risk (|entry − planned stop| × size).
    var rMultiple: Double? {
        guard let stop = plannedStop else { return nil }
        let risk = abs(averageEntry - stop) * quantity
        guard risk > 0 else { return nil }
        return (netPnL / risk).double
    }
}

nonisolated struct TradeStats: Sendable, Equatable {
    var trades = 0
    var wins = 0
    var losses = 0
    var netPnL: Decimal = 0
    var grossProfit: Decimal = 0
    var grossLoss: Decimal = 0
    var fees: Decimal = 0
    var largestWin: Decimal = 0
    var largestLoss: Decimal = 0
    var averageR: Double?
    var averageHoldWin: TimeInterval?
    var averageHoldLoss: TimeInterval?
    var maxConsecutiveLosses = 0
    var maxDrawdown: Decimal = 0

    var winRate: Double? { trades > 0 ? Double(wins) / Double(trades) : nil }
    var profitFactor: Double? { grossLoss < 0 ? (grossProfit / -grossLoss).double : nil }
    var expectancy: Decimal? { trades > 0 ? (netPnL / Decimal(trades)).rounded(Precision.cash) : nil }
    var averageWin: Decimal? { wins > 0 ? (grossProfit / Decimal(wins)).rounded(Precision.cash) : nil }
    var averageLoss: Decimal? { losses > 0 ? (grossLoss / Decimal(losses)).rounded(Precision.cash) : nil }
}

nonisolated enum TradeAnalytics {
    /// Groups fills into round trips per symbol. Partial exits stay in the same trip; a flip closes
    /// the trip and opens a new one with the remainder.
    static func roundTrips(_ account: AccountData, notes: [String: TradeNote] = [:]) -> [RoundTrip] {
        let fills = account.orders.filter { $0.status == .filled && $0.fillPrice != nil }
            .sorted { ($0.filledAt ?? $0.submittedAt) < ($1.filledAt ?? $1.submittedAt) }
        struct Open {
            var id: UUID; var isLong: Bool; var entryTime: Date
            var quantity: Decimal = 0; var maxQuantity: Decimal = 0
            var entryValue: Decimal = 0; var entryShares: Decimal = 0
            var exitValue: Decimal = 0; var exitShares: Decimal = 0
            var gross: Decimal = 0; var fees: Decimal = 0; var fills: [UUID] = []
            var plannedStop: Decimal?; var setup: String
        }
        var open: [String: Open] = [:]
        var trips: [RoundTrip] = []

        func finish(_ o: Open, exit: Date?, isOpen: Bool) -> RoundTrip {
            RoundTrip(id: o.id, symbol: "", isLong: o.isLong, entryTime: o.entryTime, exitTime: exit, quantity: o.maxQuantity,
                      averageEntry: o.entryShares > 0 ? (o.entryValue / o.entryShares).rounded(Precision.price) : 0,
                      averageExit: o.exitShares > 0 ? (o.exitValue / o.exitShares).rounded(Precision.price) : nil,
                      grossPnL: o.gross, fees: o.fees, fillIDs: o.fills, plannedStop: o.plannedStop, setup: o.setup, isOpen: isOpen)
        }
        func named(_ trip: RoundTrip, _ symbol: String) -> RoundTrip {
            RoundTrip(id: trip.id, symbol: symbol, isLong: trip.isLong, entryTime: trip.entryTime, exitTime: trip.exitTime, quantity: trip.quantity,
                      averageEntry: trip.averageEntry, averageExit: trip.averageExit, grossPnL: trip.grossPnL, fees: trip.fees,
                      fillIDs: trip.fillIDs, plannedStop: trip.plannedStop, setup: trip.setup, isOpen: trip.isOpen)
        }

        for fill in fills {
            guard let price = fill.fillPrice else { continue }
            let time = fill.filledAt ?? fill.submittedAt
            var remaining = fill.shares
            var feesLeft = fill.fees
            let buying = fill.side == .buy
            while remaining > 0 {
                if var trip = open[fill.symbol], trip.isLong != buying {
                    // Reducing.
                    let closing = min(remaining, trip.quantity)
                    let avgEntry = trip.entryValue / trip.entryShares
                    let exitNotional = Decimal.notional(closing, price)
                    let entryPortion = (avgEntry * closing).rounded(Precision.cash)
                    trip.gross += trip.isLong ? exitNotional - entryPortion : entryPortion - exitNotional
                    let fee = closing == remaining ? feesLeft : (fill.fees * closing / fill.shares).rounded(Precision.cash)
                    trip.fees += fee; feesLeft -= fee
                    trip.exitValue += exitNotional; trip.exitShares += closing
                    trip.quantity -= closing
                    if !trip.fills.contains(fill.id) { trip.fills.append(fill.id) }
                    remaining -= closing
                    if trip.quantity == 0 {
                        trips.append(named(finish(trip, exit: time, isOpen: false), fill.symbol))
                        open[fill.symbol] = nil
                    } else {
                        open[fill.symbol] = trip
                    }
                } else {
                    // Opening or adding.
                    var trip = open[fill.symbol] ?? Open(id: fill.id, isLong: buying, entryTime: time,
                                                          plannedStop: fill.plannedStop,
                                                          setup: notes[fill.id.uuidString]?.strategy ?? "Uncategorized")
                    trip.quantity += remaining
                    trip.maxQuantity = max(trip.maxQuantity, trip.quantity)
                    trip.entryValue += Decimal.notional(remaining, price)
                    trip.entryShares += remaining
                    trip.fees += feesLeft; feesLeft = 0
                    if trip.plannedStop == nil { trip.plannedStop = fill.plannedStop }
                    if !trip.fills.contains(fill.id) { trip.fills.append(fill.id) }
                    open[fill.symbol] = trip
                    remaining = 0
                }
            }
        }
        for (symbol, trip) in open { trips.append(named(finish(trip, exit: nil, isOpen: true), symbol)) }
        return trips.sorted { $0.entryTime > $1.entryTime }
    }

    static func stats(_ trips: [RoundTrip]) -> TradeStats {
        var s = TradeStats()
        let closed = trips.filter { !$0.isOpen }.sorted { ($0.exitTime ?? $0.entryTime) < ($1.exitTime ?? $1.entryTime) }
        var rs: [Double] = []
        var winHolds: [TimeInterval] = [], lossHolds: [TimeInterval] = []
        var streak = 0
        var equity: Decimal = 0, peak: Decimal = 0
        for trip in closed {
            s.trades += 1
            s.netPnL += trip.netPnL
            s.fees += trip.fees
            if trip.netPnL > 0 {
                s.wins += 1; s.grossProfit += trip.netPnL; s.largestWin = max(s.largestWin, trip.netPnL); streak = 0
                if let h = trip.holdTime { winHolds.append(h) }
            } else if trip.netPnL < 0 {
                s.losses += 1; s.grossLoss += trip.netPnL; s.largestLoss = min(s.largestLoss, trip.netPnL); streak += 1
                s.maxConsecutiveLosses = max(s.maxConsecutiveLosses, streak)
                if let h = trip.holdTime { lossHolds.append(h) }
            }
            if let r = trip.rMultiple { rs.append(r) }
            equity += trip.netPnL
            peak = max(peak, equity)
            s.maxDrawdown = min(s.maxDrawdown, equity - peak)
        }
        s.averageR = rs.isEmpty ? nil : rs.reduce(0, +) / Double(rs.count)
        s.averageHoldWin = winHolds.isEmpty ? nil : winHolds.reduce(0, +) / Double(winHolds.count)
        s.averageHoldLoss = lossHolds.isEmpty ? nil : lossHolds.reduce(0, +) / Double(lossHolds.count)
        return s
    }

    /// Net P&L per session day (keyed by ET day start), from closed trips' exit day.
    static func dailyPnL(_ trips: [RoundTrip], hours: MarketHours = .nyse) -> [Date: Decimal] {
        var result: [Date: Decimal] = [:]
        for trip in trips where !trip.isOpen {
            result[hours.dayStart(trip.exitTime ?? trip.entryTime), default: 0] += trip.netPnL
        }
        return result
    }

    /// Cumulative realized P&L after each closed trip.
    static func equityCurve(_ trips: [RoundTrip]) -> [(date: Date, value: Decimal)] {
        var total: Decimal = 0
        return trips.filter { !$0.isOpen }.sorted { ($0.exitTime ?? $0.entryTime) < ($1.exitTime ?? $1.entryTime) }.map { trip in
            total += trip.netPnL
            return (trip.exitTime ?? trip.entryTime, total)
        }
    }

    enum Grouping: String, CaseIterable, Sendable {
        case setup = "Setup", symbol = "Symbol", side = "Long / short", hour = "Entry hour (ET)", weekday = "Weekday", duration = "Hold time"
    }

    static func breakdown(_ trips: [RoundTrip], by grouping: Grouping, hours: MarketHours = .nyse) -> [(key: String, stats: TradeStats)] {
        let closed = trips.filter { !$0.isOpen }
        let calendar = hours.calendar
        let groups = Dictionary(grouping: closed) { trip -> String in
            switch grouping {
            case .setup: return trip.setup
            case .symbol: return trip.symbol
            case .side: return trip.isLong ? "Long" : "Short"
            case .hour: return String(format: "%02d:00", calendar.component(.hour, from: trip.entryTime))
            case .weekday: return calendar.weekdaySymbols[calendar.component(.weekday, from: trip.entryTime) - 1]
            case .duration:
                let minutes = (trip.holdTime ?? 0) / 60
                return minutes < 5 ? "Under 5 min" : minutes < 30 ? "5–30 min" : minutes < 120 ? "30 min–2 h" : minutes < 390 ? "2 h–1 day" : "Overnight+"
            }
        }
        let order: [String: Int] = ["Under 5 min": 0, "5–30 min": 1, "30 min–2 h": 2, "2 h–1 day": 3, "Overnight+": 4]
        return groups.map { ($0.key, stats($0.value)) }.sorted { a, b in
            switch grouping {
            case .hour: return a.key < b.key
            case .duration: return (order[a.key] ?? 9) < (order[b.key] ?? 9)
            case .weekday: return calendar.weekdaySymbols.firstIndex(of: a.key) ?? 0 < calendar.weekdaySymbols.firstIndex(of: b.key) ?? 0
            default: return a.stats.netPnL > b.stats.netPnL
            }
        }
    }
}
