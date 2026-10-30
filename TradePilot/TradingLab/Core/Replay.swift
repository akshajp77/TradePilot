import Foundation

/// Bar replay: step through a past session bar by bar and trade it with a sandbox account.
/// Each new bar is turned into four prints (open, then the nearer extreme, the far extreme, close)
/// and run through the same order engine as live trading.
nonisolated struct ReplaySession: Sendable {
    let symbol: String
    let timeframe: Timeframe
    let day: Date
    /// Bars before the replay day, shown as context.
    let history: [Bar]
    /// Bars of the replay day, revealed one at a time.
    let sessionBars: [Bar]
    private(set) var revealed: Int
    var account: AccountData
    private(set) var events: [OrderEvent] = []
    let hours: MarketHours

    init(symbol: String, timeframe: Timeframe, bars: [Bar], day: Date, startingBalance: Decimal,
         settings: TradingSettings, revealFirst: Int = 1, hours: MarketHours = .nyse) {
        self.symbol = symbol
        self.timeframe = timeframe
        self.hours = hours
        let start = hours.dayStart(day)
        self.day = start
        let regular = bars.filter { hours.isRegularSessionPrint($0.time) }
        history = Array(regular.filter { $0.time < start }.suffix(300))
        sessionBars = regular.filter { hours.isSameSessionDay($0.time, day) }
        revealed = min(max(1, revealFirst), sessionBars.count)
        var sandbox = AccountData(name: "Replay", initialBalance: startingBalance, onboardingComplete: true)
        sandbox.settings = settings
        sandbox.settings.dailyLossLimit = nil
        account = sandbox
    }

    var visibleBars: [Bar] { history + sessionBars.prefix(revealed) }
    var isFinished: Bool { revealed >= sessionBars.count }
    var currentBar: Bar? { revealed > 0 ? sessionBars[revealed - 1] : nil }
    /// The replay clock: the end of the last revealed bar.
    var now: Date { (currentBar?.time ?? day).addingTimeInterval(timeframe.seconds - 1) }
    var progress: Double { sessionBars.isEmpty ? 0 : Double(revealed) / Double(sessionBars.count) }

    /// The current quote (last close) with a synthetic spread.
    var quote: Quote? {
        guard let bar = currentBar else { return nil }
        return Quote(price: .price(bar.close), time: now, source: .replay)
    }

    var context: MarketContext {
        let price = quote?.price
        let symbol = self.symbol
        return MarketContext(price: { $0 == symbol ? price : nil }, dayPnL: nil, now: now, hours: hours)
    }

    mutating func submit(_ request: OrderRequest) -> Result<PracticeOrder, OrderRejection> {
        OrderEngine.submit(request, kind: .stock, account: &account, quote: quote, context: context)
    }

    mutating func cancel(_ id: UUID) { OrderEngine.cancel(id, account: &account, now: now) }

    /// Reveals the next bar and fills orders against its path. Returns this bar's events.
    @discardableResult
    mutating func step() -> [OrderEvent] {
        guard !isFinished else { return [] }
        let bar = sessionBars[revealed]
        revealed += 1
        var stepEvents: [OrderEvent] = []
        for (offset, price) in Self.path(bar).enumerated() {
            let time = bar.time.addingTimeInterval(timeframe.seconds * [0.0, 0.33, 0.66, 0.999][offset])
            let print = Quote(price: .price(price), time: time, source: .replay)
            let symbol = self.symbol
            let context = MarketContext(price: { $0 == symbol ? print.price : nil }, dayPnL: nil, now: time, hours: hours)
            stepEvents += OrderEngine.process(symbol: symbol, quote: print, account: &account, context: context)
        }
        if isFinished { stepEvents += OrderEngine.expire(account: &account, now: (sessionBars.last?.time ?? now).addingTimeInterval(timeframe.seconds)) }
        events += stepEvents
        return stepEvents
    }

    /// Price path assumption inside a bar: up bars go open → low → high → close, down bars open → high → low → close.
    static func path(_ bar: Bar) -> [Double] {
        bar.isUp ? [bar.open, bar.low, bar.high, bar.close] : [bar.open, bar.high, bar.low, bar.close]
    }

    /// Closes any open position at the last close and returns the summary.
    mutating func finish() -> BarReplayRecord {
        while !isFinished { step() }
        let ledger = Ledger(account, hours: hours)
        if let close = currentBar?.close, let position = ledger.position(symbol) {
            var request = OrderRequest(symbol: symbol, side: position.isLong ? .sell : .buy, shares: position.size, type: .market)
            request.reduceOnly = true
            request.role = .exit
            _ = OrderEngine.submit(request, kind: .stock, account: &account,
                                   quote: Quote(price: .price(close), time: now, source: .replay), context: context)
        }
        let trips = TradeAnalytics.roundTrips(account)
        let stats = TradeAnalytics.stats(trips)
        return BarReplayRecord(symbol: symbol, day: day, timeframe: timeframe, netPnL: stats.netPnL, trades: stats.trades, winRate: stats.winRate)
    }
}
