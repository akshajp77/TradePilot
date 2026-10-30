import Foundation

nonisolated enum QuoteSource: String, Sendable {
    case iexTrade = "IEX trade"
    case delayed = "delayed quote"
    case dailyClose = "daily close"
    case replay = "replay bar"
}

/// A price observation. Bid and ask are present when the feed provides them (IEX quotes, replay).
nonisolated struct Quote: Sendable, Equatable {
    let price: Decimal
    let time: Date
    let source: QuoteSource
    var bid: Decimal? = nil
    var ask: Decimal? = nil

    init(price: Decimal, time: Date, source: QuoteSource, bid: Decimal? = nil, ask: Decimal? = nil) {
        self.price = price; self.time = time; self.source = source; self.bid = bid; self.ask = ask
    }

    func at(_ time: Date) -> Quote { Quote(price: price, time: time, source: source, bid: bid, ask: ask) }
}

/// A signed position: quantity > 0 is long, < 0 is short. `cost` is the total entry value of |quantity|.
nonisolated struct Position: Sendable, Equatable {
    var quantity: Decimal = 0
    var cost: Decimal = 0
    var openedAt: Date = .distantPast

    var isLong: Bool { quantity > 0 }
    var isShort: Bool { quantity < 0 }
    var size: Decimal { abs(quantity) }
    var averagePrice: Decimal? { quantity != 0 ? (cost / size).rounded(Precision.price) : nil }
    func marketValue(_ price: Decimal) -> Decimal { (quantity * price).rounded(Precision.cash) }
    func unrealized(_ price: Decimal) -> Decimal {
        let value = (size * price).rounded(Precision.cash)
        return isLong ? value - cost : cost - value
    }
}

nonisolated struct RealizedTrade: Sendable, Equatable {
    let orderID: UUID
    let symbol: String
    let quantity: Decimal
    let entryValue: Decimal
    let exitValue: Decimal
    let wasShort: Bool
    let fees: Decimal
    let date: Date
    let isDayTrade: Bool
    /// Gross of fees.
    var gain: Decimal { wasShort ? entryValue - exitValue : exitValue - entryValue }
}

/// Cash, positions and returns derived from the starting balance and filled orders.
/// Orders are the single source of truth, so cash and holdings can never drift apart.
nonisolated struct Ledger: Sendable {
    let initialBalance: Decimal
    private(set) var cash: Decimal
    private(set) var positions: [String: Position] = [:]
    private(set) var realized: [RealizedTrade] = []
    private(set) var totalFees: Decimal = 0
    let fills: [PracticeOrder]
    let pending: [PracticeOrder]
    let hours: MarketHours

    init(_ account: AccountData, through cutoff: Date? = nil, hours: MarketHours = .nyse) {
        self.init(initialBalance: account.initialBalance, orders: account.orders, through: cutoff, hours: hours)
    }

    init(initialBalance: Decimal, orders: [PracticeOrder], through cutoff: Date? = nil, hours: MarketHours = .nyse) {
        self.initialBalance = initialBalance
        self.hours = hours
        cash = initialBalance
        fills = orders.filter { $0.status == .filled && $0.fillPrice != nil && (cutoff == nil || ($0.filledAt ?? $0.submittedAt) < cutoff!) }
            .sorted { ($0.filledAt ?? $0.submittedAt, $0.submittedAt) < ($1.filledAt ?? $1.submittedAt, $1.submittedAt) }
        pending = cutoff == nil ? orders.filter { $0.status.isPending } : []
        for order in fills { apply(order) }
    }

    private mutating func apply(_ order: PracticeOrder) {
        guard let price = order.fillPrice else { return }
        let time = order.filledAt ?? order.submittedAt
        let notional = Decimal.notional(order.shares, price)
        cash += order.side == .buy ? -notional : notional
        cash -= order.fees
        totalFees += order.fees

        var position = positions[order.symbol] ?? Position()
        let signed = order.side.sign * order.shares
        if position.quantity == 0 || (position.quantity > 0) == (signed > 0) {
            if position.quantity == 0 { position.openedAt = time }
            position.quantity += signed
            position.cost += notional
        } else {
            let closing = min(order.shares, position.size)
            let costRemoved = closing == position.size ? position.cost : (position.cost * closing / position.size).rounded(Precision.cash)
            let exitValue = closing == order.shares ? notional : Decimal.notional(closing, price)
            let closingFees = closing == order.shares ? order.fees : (order.fees * closing / order.shares).rounded(Precision.cash)
            realized.append(RealizedTrade(orderID: order.id, symbol: order.symbol, quantity: closing, entryValue: costRemoved,
                                          exitValue: exitValue, wasShort: position.isShort, fees: closingFees, date: time,
                                          isDayTrade: hours.isSameSessionDay(position.openedAt, time)))
            let wasLong = position.isLong
            position.quantity += signed
            position.cost -= costRemoved
            let opening = order.shares - closing
            if opening > 0 {
                // Flipped through zero: the remainder opens a new position at the fill price.
                position.quantity = wasLong ? -opening : opening
                position.cost = Decimal.notional(opening, price)
                position.openedAt = time
            }
        }
        positions[order.symbol] = position.quantity != 0 ? position : nil
    }

    // MARK: Queries

    func position(_ symbol: String) -> Position? { positions[symbol] }
    /// Signed quantity.
    func shares(_ symbol: String) -> Decimal { positions[symbol]?.quantity ?? 0 }
    var holdings: [String: Decimal] { positions.mapValues(\.quantity) }
    var heldSymbols: [String] { positions.keys.sorted() }
    func costBasis(_ symbol: String) -> Decimal? { positions[symbol].map(\.cost) }

    /// Equity: cash plus signed market value; nil while any position has no price.
    func value(price: (String) -> Decimal?) -> Decimal? {
        var total = cash
        for (symbol, position) in positions {
            guard let p = price(symbol) else { return nil }
            total += position.marketValue(p)
        }
        return total.rounded(Precision.cash)
    }

    func exposure(price: (String) -> Decimal?) -> (long: Decimal, short: Decimal)? {
        var long: Decimal = 0, short: Decimal = 0
        for (symbol, position) in positions {
            guard let p = price(symbol) else { return nil }
            let value = (position.size * p).rounded(Precision.cash)
            if position.isLong { long += value } else { short += value }
        }
        return (long, short)
    }

    /// Sale proceeds that settle on the next business day (T+1); cash accounts cannot spend them yet.
    func unsettledProceeds(asOf now: Date) -> Decimal {
        fills.filter { $0.side == .sell && hours.isSameSessionDay($0.filledAt ?? $0.submittedAt, now) }
            .reduce(0) { $0 + Decimal.notional($1.shares, $1.fillPrice ?? 0) - $1.fees }
    }

    /// Completed day trades (same-session open and close) over the last `sessions` session days.
    func dayTradeCount(asOf now: Date, sessions: Int = 5) -> Int {
        let days = Set(hours.sessionDays(endingAt: now, count: sessions))
        // One order closing a same-day position is one day trade, however many lots it closes.
        return Set(realized.filter { $0.isDayTrade && days.contains(hours.dayStart($0.date)) }.map(\.orderID)).count
    }

    var realizedNet: Decimal { realized.reduce(0) { $0 + $1.gain - $1.fees } }

    /// Opening vs closing quantity of an order against a signed position.
    static func split(side: OrderSide, shares: Decimal, position: Decimal) -> (closing: Decimal, opening: Decimal) {
        let signed = side.sign * shares
        if position == 0 || (position > 0) == (signed > 0) { return (0, shares) }
        let closing = min(shares, abs(position))
        return (closing, shares - closing)
    }

    /// v1 migration: the starting balance implied by a stored cash figure and the fills that produced it.
    static func impliedStartingBalance(cash: Decimal, orders: [PracticeOrder]) -> Decimal {
        var start = cash
        for order in orders where order.status == .filled {
            guard let price = order.fillPrice else { continue }
            start += order.side == .buy ? Decimal.notional(order.shares, price) : -Decimal.notional(order.shares, price)
        }
        return start.rounded(Precision.cash)
    }

    /// Largest peak-to-trough decline across recorded values, as a negative fraction.
    static func maxDrawdown(_ samples: [PortfolioSample], start: Double) -> Double {
        var peak = start
        var worst = 0.0
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            peak = max(peak, sample.value)
            if peak > 0 { worst = min(worst, sample.value / peak - 1) }
        }
        return worst
    }
}

// MARK: - Day P&L

nonisolated enum DayPnL {
    /// P&L for one symbol since the start of today's ET session day: value now − value at the
    /// previous close − today's net cash spent on it (fees included). Works for longs, shorts and flips.
    static func symbol(_ symbol: String, account: AccountData, price: Decimal, previousClose: Decimal?,
                       now: Date, hours: MarketHours = .nyse) -> Decimal? {
        let dayStart = hours.dayStart(now)
        let start = Ledger(account, through: dayStart, hours: hours)
        let startQuantity = start.shares(symbol)
        if startQuantity != 0 && previousClose == nil { return nil }
        var cashSpent: Decimal = 0
        var touched = startQuantity != 0
        for order in account.orders where order.symbol == symbol && order.status == .filled {
            guard let fill = order.fillPrice, let filledAt = order.filledAt, filledAt >= dayStart else { continue }
            cashSpent += order.side.sign * Decimal.notional(order.shares, fill) + order.fees
            touched = true
        }
        guard touched else { return nil }
        let nowValue = (Ledger(account, hours: hours).shares(symbol) * price).rounded(Precision.cash)
        let startValue = (startQuantity * (previousClose ?? 0)).rounded(Precision.cash)
        return nowValue - startValue - cashSpent
    }

    /// Account P&L for today: the sum over every symbol held at the open or traded today.
    static func account(_ account: AccountData, price: (String) -> Decimal?, previousClose: (String) -> Decimal?,
                        now: Date, hours: MarketHours = .nyse) -> Decimal? {
        let dayStart = hours.dayStart(now)
        let start = Ledger(account, through: dayStart, hours: hours)
        var symbols = Set(start.heldSymbols)
        for order in account.orders where order.status == .filled && (order.filledAt ?? .distantPast) >= dayStart { symbols.insert(order.symbol) }
        var total: Decimal = 0
        for s in symbols {
            guard let p = price(s) ?? previousClose(s),
                  let pnl = DayPnL.symbol(s, account: account, price: p, previousClose: previousClose(s), now: now, hours: hours) else { return nil }
            total += pnl
        }
        return total
    }
}

// MARK: - Margin

nonisolated struct MarginSnapshot: Sendable, Equatable {
    let equity: Decimal
    let cash: Decimal
    let longValue: Decimal
    let shortValue: Decimal
    let maintenanceRequirement: Decimal
    let buyingPower: Decimal
    let reserved: Decimal
    let leverage: Bool
    var availableBuyingPower: Decimal { max(0, buyingPower - reserved) }
    var excessEquity: Decimal { equity - maintenanceRequirement }
    var hasDeficit: Bool { equity < maintenanceRequirement }
    var debitBalance: Decimal { max(0, -cash) }
}

nonisolated enum Margin {
    /// Buying power rules:
    /// - Cash account: settled cash only (sale proceeds settle T+1). No shorting.
    /// - Margin account under $2,000 equity: no leverage, no shorting.
    /// - Margin account: Reg T 50% initial → 2× excess equity. Maintenance (house rate) is checked per trade.
    static func snapshot(account: AccountData, ledger: Ledger, price: (String) -> Decimal?, now: Date) -> MarginSnapshot? {
        guard let equity = ledger.value(price: price), let exposure = ledger.exposure(price: price) else { return nil }
        let settings = account.settings
        let leverage = settings.accountType == .margin && equity >= TradingSettings.marginMinimumEquity
        let gross = exposure.long + exposure.short
        let buyingPower: Decimal
        switch settings.accountType {
        case .cash: buyingPower = max(0, ledger.cash - ledger.unsettledProceeds(asOf: now))
        case .margin: buyingPower = leverage ? max(0, (equity - gross * TradingSettings.regTInitial) / TradingSettings.regTInitial) : max(0, ledger.cash)
        }
        let reserved = ledger.pending.reduce(Decimal(0)) { total, order in
            total + reservation(order, position: ledger.shares(order.symbol), settings: settings)
        }
        return MarginSnapshot(equity: equity, cash: ledger.cash, longValue: exposure.long, shortValue: exposure.short,
                              maintenanceRequirement: (gross * settings.maintenanceRate).rounded(Precision.cash),
                              buyingPower: buyingPower.rounded(Precision.cash), reserved: reserved.rounded(Precision.cash), leverage: leverage)
    }

    /// Buying power held by a working order for the part of it that opens or adds to a position.
    static func reservation(_ order: PracticeOrder, position: Decimal, settings: TradingSettings) -> Decimal {
        guard order.status.isWorking, !order.reduceOnly else { return 0 }
        let opening = Ledger.split(side: order.side, shares: order.shares, position: position).opening
        guard opening > 0 else { return 0 }
        let price = order.limit ?? order.stop ?? order.trailAnchor ?? order.reference ?? 0
        return Decimal.notional(opening, price) + settings.fees(shares: order.shares)
    }
}
