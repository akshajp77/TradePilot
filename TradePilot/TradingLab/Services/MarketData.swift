import Foundation
import Combine

struct LiveTrade: Equatable {
    let price: Double
    let time: Date
    let previousClose: Double?
}

struct DelayedQuote: Equatable {
    let price: Double
    let previousClose: Double?
    let time: Date
}

/// Best bid and offer (IEX).
struct Level1: Equatable {
    let bid: Double
    let bidSize: Double
    let ask: Double
    let askSize: Double
    let time: Date
    var spread: Double { ask - bid }
    var mid: Double { (bid + ask) / 2 }
}

/// One print on the time & sales tape.
struct TapePrint: Identifiable, Equatable {
    enum Side { case ask, bid, mid }
    let id = UUID()
    let price: Double
    let size: Double
    let time: Date
    let side: Side
}

struct StockStatistics: Equatable {
    var open: Double?
    var high: Double?
    var low: Double?
    var volume: Double?
    var fiftyTwoWeekHigh: Double?
    var fiftyTwoWeekLow: Double?
    var exchange: String?
    var marketCap: Double?
    var peRatio: Double?
    var eps: Double?
    var beta: Double?
    var dividendYield: Double?
}

/// Prices, candles, quotes and the tape. Every print goes to `onQuote` immediately (orders and
/// alerts); published state, which redraws views, is coalesced to one update per `marketPublishInterval`.
@MainActor
final class MarketData: ObservableObject {
    enum FeedState: Equatable {
        case loading, delayed, connecting, live, reconnecting, error(String), offline
    }

    @Published private(set) var trades: [String: LiveTrade] = [:]
    @Published private(set) var delayed: [String: DelayedQuote] = [:]
    @Published private(set) var level1: [String: Level1] = [:]
    @Published private(set) var feed: FeedState = .loading
    @Published private(set) var statistics: [String: StockStatistics] = [:]
    @Published private(set) var series: [String: [ChartRange: [PricePoint]]] = [:]
    @Published private(set) var bars: [String: [Timeframe: [Bar]]] = [:]
    @Published private(set) var loadingSeries: Set<String> = []
    @Published private(set) var seriesErrors: Set<String> = []
    @Published private(set) var earnings: [String: [EarningsDate]] = [:]
    /// Time & sales for the focused symbol, newest first.
    @Published private(set) var tape: [TapePrint] = []
    @Published private(set) var focusSymbol: String?
    /// Last time any price arrived from any source.
    @Published private(set) var lastPriceAt: Date?
    /// Cached: reading the Keychain on every status redraw is slow.
    @Published private(set) var configured = Feeds.alpacaCredentials != nil

    /// Every price print, unthrottled. Used for order execution and alerts.
    var onQuote: ((String, Quote) -> Void)?
    /// Fires after bars for a symbol change (new candle or reload); used by indicator alerts.
    var onBars: ((String) -> Void)?

    let hours = MarketHours.nyse
    private var trackedSymbols: [String] = []
    private var streamSymbols: [String] = []
    private var focusTimeframe: Timeframe = .m5
    private var seriesLoadedAt: [String: Date] = [:]
    private var fundamentalsLoadedAt: [String: Date] = [:]
    private var earningsLoadedAt: [String: Date] = [:]
    private var socket: URLSessionWebSocketTask?
    private var streamLoop: Task<Void, Never>?
    private var pollLoop: Task<Void, Never>?
    private var focusLoop: Task<Void, Never>?
    private var generation = 0

    // Batching
    private struct PendingPrint { let price: Double; let size: Double; let time: Date }
    private var pendingTrades: [String: LiveTrade] = [:]
    private var pendingPrints: [String: [PendingPrint]] = [:]
    private var pendingLevel1: [String: Level1] = [:]
    private var pendingTape: [TapePrint] = []
    private var flushTask: Task<Void, Never>?

    init() {}

    func setTracked(_ securities: [Security], reconnect: Bool = true) {
        let all = Array(Set(securities.map(\.symbol))).sorted()
        let streamable = Array(Set(securities.filter { $0.kind != .index }.map(\.symbol))).sorted()
        guard all != trackedSymbols || streamable != streamSymbols else { return }
        let added = Set(all).subtracting(trackedSymbols)
        trackedSymbols = all
        streamSymbols = streamable
        if reconnect { connect() }
        else if !added.isEmpty { Task { await loadDelayed(Array(added)) } }
    }

    // MARK: Reading prices

    private func displayedTrade(_ symbol: String) -> LiveTrade? {
        guard let trade = trades[symbol] else { return nil }
        if let quote = delayed[symbol], trade.time < quote.time { return nil }
        return trade
    }

    func price(_ symbol: String) -> Double? { displayedTrade(symbol)?.price ?? delayed[symbol]?.price }
    func decimalPrice(_ symbol: String) -> Decimal? { price(symbol).map(Decimal.price) }
    func previousClose(_ symbol: String) -> Double? { displayedTrade(symbol)?.previousClose ?? delayed[symbol]?.previousClose }
    func decimalPreviousClose(_ symbol: String) -> Decimal? { previousClose(symbol).map(Decimal.price) }

    func change(_ symbol: String) -> Double? {
        guard let current = price(symbol), let previous = previousClose(symbol), previous > 0 else { return nil }
        return (current / previous - 1) * 100
    }

    /// Newest price as an execution quote, with the IEX bid/ask when it is current.
    func quote(_ symbol: String) -> Quote? {
        var result: Quote?
        if let trade = displayedTrade(symbol) { result = Quote(price: .price(trade.price), time: trade.time, source: .iexTrade) }
        else if let q = delayed[symbol] { result = Quote(price: .price(q.price), time: q.time, source: hours.isOpen(at: q.time) ? .delayed : .dailyClose) }
        guard var quote = result else { return nil }
        if let l1 = level1[symbol], abs(l1.time.timeIntervalSince(quote.time)) < 10, l1.bid > 0, l1.ask >= l1.bid,
           l1.spread / max(l1.mid, 0.01) < 0.05 { // ignore crossed or absurd IEX quotes on thin names
            quote.bid = .price(l1.bid)
            quote.ask = .price(l1.ask)
        }
        return quote
    }

    func quoteLabel(_ symbol: String, now: Date = Date()) -> String {
        guard let quote = quote(symbol) else { return "Price unavailable" }
        let when = Calendar.current.isDate(quote.time, inSameDayAs: now)
            ? quote.time.formatted(date: .omitted, time: .shortened)
            : quote.time.formatted(date: .abbreviated, time: .shortened)
        let session: String
        switch hours.sessionKind(at: quote.time) {
        case .pre: session = " · pre-market"
        case .post: session = " · after hours"
        default: session = ""
        }
        switch quote.source {
        case .iexTrade: return "IEX trade · \(when)\(session)"
        case .delayed: return "Delayed quote · \(when)\(session)"
        case .dailyClose: return "Last close · \(when)"
        case .replay: return "Replay"
        }
    }

    func points(_ symbol: String, range: ChartRange) -> [PricePoint] { series[symbol]?[range] ?? [] }
    func candles(_ symbol: String, _ timeframe: Timeframe) -> [Bar] { bars[symbol]?[timeframe] ?? [] }
    func isLoading(_ symbol: String, range: ChartRange) -> Bool { loadingSeries.contains(key(symbol, range.rawValue)) }
    func isLoading(_ symbol: String, timeframe: Timeframe) -> Bool { loadingSeries.contains(key(symbol, "bars-" + timeframe.rawValue)) }
    func hasError(_ symbol: String, timeframe: Timeframe) -> Bool { seriesErrors.contains(key(symbol, "bars-" + timeframe.rawValue)) }
    func hasSeriesError(_ symbol: String, range: ChartRange) -> Bool { seriesErrors.contains(key(symbol, range.rawValue)) }
    private func key(_ symbol: String, _ suffix: String) -> String { "\(symbol):\(suffix)" }

    func nextEarnings(_ symbol: String, after date: Date = Date()) -> EarningsDate? {
        earnings[symbol]?.first { $0.date >= hours.dayStart(date) }
    }

    var statusText: String {
        switch feed {
        case .loading: return "Loading market prices…"
        case .delayed: return configured ? "Delayed prices · IEX unavailable" : "Delayed prices · connect IEX in Settings for live trades and quotes"
        case .connecting: return "Connecting to IEX…"
        case .live: return "Live · IEX trades and quotes"
        case .reconnecting: return "Reconnecting to IEX…"
        case .error(let message): return "Feed error: \(message)"
        case .offline: return "Offline · showing the last loaded prices"
        }
    }

    // MARK: Focus (the symbol on the chart)

    /// The chart's symbol gets the tape, faster candle refresh without IEX, and earnings dates.
    func focus(_ symbol: String?, timeframe: Timeframe) {
        let changed = symbol != focusSymbol
        focusSymbol = symbol
        focusTimeframe = timeframe
        if changed { tape = []; pendingTape = [] }
        focusLoop?.cancel()
        guard let symbol else { return }
        focusLoop = Task { [weak self] in
            await self?.loadEarnings(symbol)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                // With a live stream the candles build themselves; otherwise refresh them during sessions.
                if self.feed != .live && self.hours.sessionKind(at: Date()) != .closed {
                    await self.loadBars(symbol, timeframe: self.focusTimeframe, force: true)
                }
            }
        }
    }

    // MARK: Connection lifecycle

    func configure(key: String, secret: String) {
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: .alpacaKey)
        Keychain.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: .alpacaSecret)
        configured = Feeds.alpacaCredentials != nil
        if !configured { trades = [:]; level1 = [:] }
        connect()
    }

    func disconnect() {
        generation += 1
        streamLoop?.cancel(); streamLoop = nil
        pollLoop?.cancel(); pollLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func connect() {
        disconnect()
        let current = generation
        pollLoop = Task { [weak self] in
            guard let self else { return }
            await self.loadDelayed(self.trackedSymbols)
            // Poll delayed quotes every minute during sessions (pre-market and after-hours included)
            // so queued orders, limits and alerts see current prices without a stream.
            while !Task.isCancelled, current == self.generation {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, current == self.generation else { return }
                guard self.hours.sessionKind(at: Date()) != .closed else { continue }
                let symbols = self.feed == .live ? self.trackedSymbols.filter { !self.streamSymbols.contains($0) } : self.trackedSymbols
                if !symbols.isEmpty { await self.loadDelayed(symbols) }
            }
        }
        guard let credentials = Feeds.alpacaCredentials else { return }
        streamLoop = Task { [weak self] in
            while let self, !Task.isCancelled, current == self.generation {
                await self.loadSnapshots(credentials)
                await self.stream(credentials, current: current)
                if Task.isCancelled || current != self.generation { return }
                if case .error = self.feed { return } // bad keys: do not hammer the endpoint
                self.feed = .reconnecting
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() {
        if streamLoop == nil && pollLoop == nil { connect(); return }
        Task { await loadDelayed(trackedSymbols) }
    }

    // MARK: Delayed quotes (Yahoo chart JSON)

    func loadDelayed(_ symbols: [String]) async {
        guard !symbols.isEmpty else { return }
        let payloads = await concurrentMap(symbols, limit: AppConfig.fetchConcurrency) { symbol in
            await Feeds.yahooChart(symbol, range: "1mo", interval: "1d")
        }
        var received = 0
        for case let payload? in payloads { if apply(payload) { received += 1 } }
        if received > 0 {
            switch feed {
            case .loading, .offline: feed = configured ? .connecting : .delayed
            default: if !configured { feed = .delayed }
            }
        } else if feed != .live {
            feed = .offline
        }
    }

    @discardableResult
    private func apply(_ payload: ChartPayload) -> Bool {
        let symbol = payload.symbol
        guard let price = payload.price, price > 0 else { return false }
        let time = payload.time ?? payload.points.last?.date ?? Date()
        // Previous close = last daily bar from an earlier session than the quote.
        let previous = payload.points.last(where: { !hours.isSameSessionDay($0.date, time) })?.price ?? payload.previousClose
        let isNewer = (delayed[symbol]?.time).map { time > $0 } ?? true
        delayed[symbol] = DelayedQuote(price: price, previousClose: previous, time: time)
        var stats = statistics[symbol] ?? StockStatistics()
        stats.open = payload.open ?? stats.open
        stats.high = payload.dayHigh ?? stats.high
        stats.low = payload.dayLow ?? stats.low
        stats.volume = payload.volume ?? stats.volume
        stats.fiftyTwoWeekHigh = payload.fiftyTwoWeekHigh ?? stats.fiftyTwoWeekHigh
        stats.fiftyTwoWeekLow = payload.fiftyTwoWeekLow ?? stats.fiftyTwoWeekLow
        stats.exchange = payload.exchange ?? stats.exchange
        statistics[symbol] = stats
        if !payload.points.isEmpty { series[symbol, default: [:]][.month] = payload.points }
        lastPriceAt = max(lastPriceAt ?? .distantPast, time)
        if isNewer {
            if feed != .live || !streamSymbols.contains(symbol) {
                // No stream for this symbol: move the open candles with the delayed price.
                pendingPrints[symbol, default: []].append(PendingPrint(price: price, size: 0, time: time))
                scheduleFlush()
            }
            onQuote?(symbol, Quote(price: .price(price), time: time, source: hours.isOpen(at: time) ? .delayed : .dailyClose))
        }
        return true
    }

    // MARK: Charts

    func loadSeries(_ symbol: String, range: ChartRange, force: Bool = false) async {
        let k = key(symbol, range.rawValue)
        if !force, series[symbol]?[range] != nil, let loaded = seriesLoadedAt[k], Date().timeIntervalSince(loaded) < 300 { return }
        guard !loadingSeries.contains(k) else { return }
        loadingSeries.insert(k)
        seriesErrors.remove(k)
        defer { loadingSeries.remove(k) }
        let request = range.request
        guard let payload = await Feeds.yahooChart(symbol, range: request.range, interval: request.interval), !payload.points.isEmpty else {
            seriesErrors.insert(k)
            return
        }
        var points = payload.points
        if range == .hour, let end = points.last?.date { points = points.filter { $0.date >= end.addingTimeInterval(-3600) } }
        series[symbol, default: [:]][range] = points
        seriesLoadedAt[k] = Date()
    }

    /// OHLCV candles for the chart. Daily and weekly bars are normalized to session-open timestamps
    /// so live prints merge into the right candle.
    func loadBars(_ symbol: String, timeframe: Timeframe, force: Bool = false) async {
        let k = key(symbol, "bars-" + timeframe.rawValue)
        if !force, bars[symbol]?[timeframe] != nil, let loaded = seriesLoadedAt[k], Date().timeIntervalSince(loaded) < 120 { return }
        guard !loadingSeries.contains(k) else { return }
        let showSpinner = bars[symbol]?[timeframe] == nil
        if showSpinner { loadingSeries.insert(k) }
        seriesErrors.remove(k)
        defer { if showSpinner { loadingSeries.remove(k) } }
        guard let payload = await Feeds.yahooBars(symbol, timeframe: timeframe) else {
            if bars[symbol]?[timeframe] == nil { seriesErrors.insert(k) }
            return
        }
        var loaded = payload.bars
        if !timeframe.isIntraday {
            loaded = loaded.map { var bar = $0; bar.time = timeframe.bucketStart(for: $0.time, hours: hours); return bar }
            var merged: [Bar] = []
            for bar in loaded { if merged.last?.time == bar.time { merged[merged.count - 1] = bar } else { merged.append(bar) } }
            loaded = merged
        }
        // Keep candles that live prints built after Yahoo's last bar.
        if let existing = bars[symbol]?[timeframe], let lastLoaded = loaded.last?.time {
            loaded += existing.filter { $0.time > lastLoaded }
        }
        bars[symbol, default: [:]][timeframe] = loaded
        seriesLoadedAt[k] = Date()
        if payload.price != nil { apply(payload) }
        onBars?(symbol)
    }

    func loadEarnings(_ symbol: String) async {
        if let loaded = earningsLoadedAt[symbol], Date().timeIntervalSince(loaded) < 6 * 3600 { return }
        earningsLoadedAt[symbol] = Date()
        if let rows = await Feeds.earnings(symbol) { earnings[symbol] = rows } else { earningsLoadedAt[symbol] = nil }
    }

    // MARK: Fundamentals (server proxy)

    func loadFundamentals(_ symbol: String) async { await loadFundamentals([symbol]) }

    func loadFundamentals(_ symbols: [String]) async {
        let now = Date()
        let pending = symbols.filter { fundamentalsLoadedAt[$0].map { now.timeIntervalSince($0) > 6 * 3600 } ?? true }
        for symbol in pending { fundamentalsLoadedAt[symbol] = now }
        let results = await concurrentMap(pending, limit: AppConfig.fetchConcurrency) { symbol in (symbol, await Feeds.fundamentals(symbol)) }
        for (symbol, f) in results {
            guard let f else { fundamentalsLoadedAt[symbol] = nil; continue }
            var stats = statistics[symbol] ?? StockStatistics()
            stats.marketCap = f.marketCap ?? stats.marketCap
            stats.peRatio = f.peRatio; stats.eps = f.eps; stats.beta = f.beta; stats.dividendYield = f.dividendYield
            stats.fiftyTwoWeekHigh = stats.fiftyTwoWeekHigh ?? f.fiftyTwoWeekHigh
            stats.fiftyTwoWeekLow = stats.fiftyTwoWeekLow ?? f.fiftyTwoWeekLow
            statistics[symbol] = stats
        }
    }

    // MARK: Scanner

    /// Market-wide scan: Alpaca's screener when keys are connected, else Yahoo's predefined screens.
    func scan(_ preset: ScanPreset) async -> [ScanRow]? {
        if let credentials = Feeds.alpacaCredentials, [.gainers, .losers, .active].contains(preset) {
            if preset == .active, let actives = await Feeds.alpacaActives(credentials), !actives.isEmpty {
                return actives.map { row in
                    ScanRow(symbol: row.symbol, name: row.symbol, price: price(row.symbol) ?? 0, changePercent: change(row.symbol) ?? 0, volume: row.volume)
                }
            }
            if preset != .active, let movers = await Feeds.alpacaMovers(credentials) {
                let rows = preset == .gainers ? movers.gainers : movers.losers
                if !rows.isEmpty { return rows }
            }
        }
        let lists = await concurrentMap(preset.yahooIDs, limit: 3) { id in await Feeds.yahooScreener(id) ?? [] }
        var seen = Set<String>()
        let merged = lists.flatMap { $0 }.filter { seen.insert($0.symbol).inserted }
        return merged.isEmpty ? nil : preset.rank(merged)
    }

    // MARK: IEX via Alpaca

    private func loadSnapshots(_ credentials: Feeds.AlpacaCredentials) async {
        let snapshots = await concurrentMap(streamSymbols, limit: AppConfig.fetchConcurrency) { symbol in
            (symbol, await Feeds.alpacaSnapshot(symbol, credentials))
        }
        for (symbol, snapshot) in snapshots {
            guard let snapshot else { continue }
            trades[symbol] = LiveTrade(price: snapshot.price, time: snapshot.time, previousClose: snapshot.previousClose)
            lastPriceAt = max(lastPriceAt ?? .distantPast, snapshot.time)
            onQuote?(symbol, Quote(price: .price(snapshot.price), time: snapshot.time, source: .iexTrade))
        }
    }

    private func send(_ payload: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func stream(_ credentials: Feeds.AlpacaCredentials, current: Int) async {
        let task = URLSession.shared.webSocketTask(with: URL(string: "wss://stream.data.alpaca.markets/v2/iex")!)
        socket = task
        feed = .connecting
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        do {
            try await send(["action": "auth", "key": credentials.key, "secret": credentials.secret], on: task)
            while !Task.isCancelled && current == generation {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                for event in await offMain({ Parse.alpacaStream(data) }) {
                    switch event {
                    case .authenticated:
                        try await send(["action": "subscribe", "trades": streamSymbols, "quotes": streamSymbols], on: task)
                    case .subscribed: feed = .live
                    case .error(let message):
                        feed = .error(message)
                        return
                    case let .trade(symbol, price, size, time): receive(symbol: symbol, price: price, size: size, time: time)
                    case let .quote(symbol, bid, bidSize, ask, askSize, time):
                        pendingLevel1[symbol] = Level1(bid: bid, bidSize: bidSize, ask: ask, askSize: askSize, time: time)
                        scheduleFlush()
                    }
                }
            }
        } catch {
            if current == generation && feed != .reconnecting { feed = .reconnecting }
        }
    }

    private func receive(symbol: String, price: Double, size: Double, time: Date) {
        let previous = pendingTrades[symbol]?.previousClose ?? trades[symbol]?.previousClose ?? delayed[symbol]?.previousClose
        pendingTrades[symbol] = LiveTrade(price: price, time: time, previousClose: previous)
        pendingPrints[symbol, default: []].append(PendingPrint(price: price, size: size, time: time))
        if symbol == focusSymbol {
            let l1 = pendingLevel1[symbol] ?? level1[symbol]
            let side: TapePrint.Side = l1.map { price >= $0.ask ? .ask : price <= $0.bid ? .bid : .mid } ?? .mid
            pendingTape.append(TapePrint(price: price, size: size, time: time, side: side))
        }
        var quote = Quote(price: .price(price), time: time, source: .iexTrade)
        if let l1 = pendingLevel1[symbol] ?? level1[symbol], abs(l1.time.timeIntervalSince(time)) < 10 {
            quote.bid = .price(l1.bid); quote.ask = .price(l1.ask)
        }
        onQuote?(symbol, quote)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.marketPublishInterval)
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        if !pendingLevel1.isEmpty {
            var updated = level1
            for (symbol, value) in pendingLevel1 { updated[symbol] = value }
            pendingLevel1.removeAll(keepingCapacity: true)
            level1 = updated
        }
        if !pendingTape.isEmpty {
            tape = Array((pendingTape.reversed() + tape).prefix(300))
            pendingTape.removeAll(keepingCapacity: true)
        }
        guard !pendingPrints.isEmpty || !pendingTrades.isEmpty else { return }
        var updatedTrades = trades
        for (symbol, trade) in pendingTrades { updatedTrades[symbol] = trade }
        var updatedSeries = series
        var updatedBars = bars
        var newCandles: Set<String> = []
        for (symbol, prints) in pendingPrints {
            for range in [ChartRange.hour, .day] where updatedSeries[symbol]?[range] != nil {
                guard let last = prints.last?.time else { continue }
                let cutoff = last.addingTimeInterval(range == .hour ? -3600 : -86_400)
                var merged = updatedSeries[symbol]![range]! + prints.map { PricePoint(date: $0.time, price: $0.price) }
                if let firstKept = merged.firstIndex(where: { $0.date >= cutoff }) { merged.removeFirst(firstKept) }
                updatedSeries[symbol]![range] = merged
            }
            for timeframe in (updatedBars[symbol] ?? [:]).keys {
                var candles = updatedBars[symbol]![timeframe]!
                for print in prints {
                    let started = BarAggregator.apply(price: print.price, size: print.size, time: print.time,
                                                      to: &candles, timeframe: timeframe, hours: hours)
                    if started { newCandles.insert(symbol) }
                }
                updatedBars[symbol]![timeframe] = candles
            }
        }
        let latest = pendingTrades.values.map(\.time).max()
        pendingTrades.removeAll(keepingCapacity: true)
        pendingPrints.removeAll(keepingCapacity: true)
        trades = updatedTrades
        series = updatedSeries
        bars = updatedBars
        if let latest { lastPriceAt = max(lastPriceAt ?? .distantPast, latest) }
        for symbol in newCandles { onBars?(symbol) }
    }
}
