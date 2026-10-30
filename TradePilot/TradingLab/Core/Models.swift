import Foundation

// MARK: - Securities

nonisolated enum SecurityKind: String, Codable, CaseIterable, Sendable {
    case stock = "Stock", etf = "ETF", index = "Index"
    var tradable: Bool { self != .index }
}

nonisolated struct Security: Identifiable, Codable, Hashable, Sendable {
    let symbol: String
    let name: String
    let kind: SecurityKind
    let description: String
    let sector: String
    /// When the user added it (custom securities only); lets a re-add beat an older deletion during sync.
    var addedAt: Date?
    var id: String { symbol }

    init(symbol: String, name: String, kind: SecurityKind, description: String, sector: String, addedAt: Date? = nil) {
        self.symbol = symbol; self.name = name; self.kind = kind; self.description = description; self.sector = sector
        self.addedAt = addedAt
    }
    private enum CodingKeys: String, CodingKey { case symbol, name, kind, description, sector, addedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? symbol
        // v1 stored free text ("Illustrative stock"); anything unknown is a stock.
        kind = SecurityKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .stock
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        sector = try c.decodeIfPresent(String.self, forKey: .sector) ?? "US market"
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
    }
}

nonisolated enum MarketCatalog {
    static let securities: [Security] = [
        .init(symbol: "AAPL", name: "Apple", kind: .stock, description: "Research hardware, services, margins and earnings before forming a view.", sector: "Technology"),
        .init(symbol: "MSFT", name: "Microsoft", kind: .stock, description: "Compare cloud growth, software revenue and valuation with your thesis.", sector: "Technology"),
        .init(symbol: "SPY", name: "SPDR S&P 500 ETF", kind: .etf, description: "A broad US equity fund. It reduces single-company exposure but can still fall.", sector: "Broad market"),
        .init(symbol: "TSLA", name: "Tesla", kind: .stock, description: "Study deliveries, competition, margins and concentration before sizing a position.", sector: "Consumer"),
    ]
    static func security(_ symbol: String) -> Security? { securities.first { $0.symbol == symbol } }
}

// MARK: - Account

nonisolated struct AccountData: Codable, Hashable, Sendable {
    static let defaultBalance: Decimal = 100_000
    var initialBalance: Decimal = AccountData.defaultBalance
    var name = ""
    var goal = "Learn to trade"
    var orders: [PracticeOrder] = []
    var watched = ["SPY", "AAPL"]
    var completedLessons: [String] = []
    var completedChecks: [String] = []
    var onboardingComplete = false
    /// Bumped by reset; sync keeps the newer epoch wholesale instead of merging orders across a reset.
    var resetAt: Date = .distantPast
    /// Last change to the scalar fields above (name, goal, balance, settings); used to merge them.
    var updatedAt: Date = .distantPast
    var settings = TradingSettings()

    init(name: String = "", goal: String = "Learn to trade", initialBalance: Decimal = AccountData.defaultBalance,
         onboardingComplete: Bool = false) {
        self.name = name; self.goal = goal; self.initialBalance = initialBalance; self.onboardingComplete = onboardingComplete
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, initialBalance, name, goal, orders, watched, completedLessons, completedChecks
        case onboardingComplete, resetAt, updatedAt, settings
        case cash // v1 only
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? "Learn to trade"
        orders = try c.decodeIfPresent([PracticeOrder].self, forKey: .orders) ?? []
        watched = try c.decodeIfPresent([String].self, forKey: .watched) ?? ["SPY", "AAPL"]
        completedLessons = try c.decodeIfPresent([String].self, forKey: .completedLessons) ?? []
        completedChecks = try c.decodeIfPresent([String].self, forKey: .completedChecks) ?? []
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        resetAt = try c.decodeIfPresent(Date.self, forKey: .resetAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        settings = (try? c.decodeIfPresent(TradingSettings.self, forKey: .settings)) ?? TradingSettings()
        let storedBalance = try c.decodeIfPresent(Decimal.self, forKey: .initialBalance)?.rounded(Precision.cash)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if version < 2, let legacyCash = try c.decodeIfPresent(Decimal.self, forKey: .cash) {
            // v1 tracked cash separately and could disagree with its own baseline (the 10k→100k migration).
            // Cash is what the user saw, so back the true starting balance out of it.
            let implied = Ledger.impliedStartingBalance(cash: legacyCash.rounded(Precision.cash), orders: orders)
            if let storedBalance, abs((storedBalance - implied).double) < 1 { initialBalance = storedBalance }
            else { initialBalance = max(0, implied) }
        } else {
            initialBalance = storedBalance ?? AccountData.defaultBalance
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .schemaVersion)
        try c.encode(initialBalance, forKey: .initialBalance)
        try c.encode(name, forKey: .name)
        try c.encode(goal, forKey: .goal)
        try c.encode(orders, forKey: .orders)
        try c.encode(watched, forKey: .watched)
        try c.encode(completedLessons, forKey: .completedLessons)
        try c.encode(completedChecks, forKey: .completedChecks)
        try c.encode(onboardingComplete, forKey: .onboardingComplete)
        try c.encode(resetAt, forKey: .resetAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(settings, forKey: .settings)
    }
}

nonisolated struct PortfolioSample: Codable, Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let value: Double
}

nonisolated struct Portfolio: Identifiable, Codable, Hashable, Sendable {
    static let primaryID = "primary"
    var id: String
    var title: String
    var account: AccountData
    var history: [PortfolioSample] = []
}

// MARK: - Workspace features

nonisolated struct NamedWatchlist: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var title: String
    var symbols: [String] = []
    var pinned: [String] = []
}

nonisolated struct TradeNote: Codable, Hashable, Sendable {
    /// Setups for day trades first, then longer-horizon styles.
    static let strategies = ["Uncategorized", "Breakout", "Pullback", "VWAP reclaim", "Opening range", "Gap and go", "Reversal",
                             "News", "Momentum", "Long-term", "Value", "Growth", "Income", "Experiment"]
    static let emotions = ["Neutral", "Patient", "Excited", "Anxious", "Rushed", "Frustrated"]
    var strategy = "Uncategorized"
    var confidence = 3
    var emotion = "Neutral"
    var followedPlan: Bool? = nil
    var chart: [Double] = []
}

nonisolated struct SavedResearch: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.absoluteString }
    var title: String
    var source: String
    var url: URL
    var date: Date
    var symbol: String
    var note = ""
    var quote = ""
    var savedAt = Date()
}

nonisolated struct ScheduledInvestment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var portfolio: String
    var symbol: String
    var dollars: Decimal
    var intervalDays: Int
    var nextDate: Date
    var enabled = true
    var lastMessage = "Waiting for scheduled date"
}

nonisolated struct TrackedEvent: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var symbol: String
    var kind: String
    var date: Date
    var expected = ""
    var actual = ""
    var note = ""
}

nonisolated enum AlertCondition: Codable, Hashable, Sendable {
    case priceAbove(Decimal)
    case priceBelow(Decimal)
    /// Percent change from the previous close, in percent points (5 = +5%).
    case changeAbove(Double)
    case changeBelow(Double)
    case crossesAboveVWAP
    case crossesBelowVWAP
    /// RSI(14) on 5-minute bars.
    case rsiAbove(Double)
    case rsiBelow(Double)
    /// Today's volume vs the average daily volume at this time of day.
    case relativeVolumeAbove(Double)

    var title: String {
        switch self {
        case .priceAbove(let p): return "Price ≥ \(Format.money(p))"
        case .priceBelow(let p): return "Price ≤ \(Format.money(p))"
        case .changeAbove(let x): return "Change ≥ \(Format.percent(x / 100, digits: 1))"
        case .changeBelow(let x): return "Change ≤ \(Format.percent(x / 100, digits: 1))"
        case .crossesAboveVWAP: return "Crosses above VWAP"
        case .crossesBelowVWAP: return "Crosses below VWAP"
        case .rsiAbove(let x): return "RSI(14, 5m) ≥ \(Int(x))"
        case .rsiBelow(let x): return "RSI(14, 5m) ≤ \(Int(x))"
        case .relativeVolumeAbove(let x): return "Relative volume ≥ \(String(format: "%.1f", x))×"
        }
    }
    var needsIntradayBars: Bool {
        switch self {
        case .crossesAboveVWAP, .crossesBelowVWAP, .rsiAbove, .rsiBelow, .relativeVolumeAbove: return true
        default: return false
        }
    }
}

nonisolated struct PriceAlert: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var symbol: String
    var condition: AlertCondition
    var note = ""
    /// Re-arms after triggering instead of firing once.
    var repeats = false
    var triggeredAt: Date? = nil
    var createdAt = Date()

    init(id: String = UUID().uuidString, symbol: String, condition: AlertCondition, note: String = "", repeats: Bool = false) {
        self.id = id; self.symbol = symbol; self.condition = condition; self.note = note; self.repeats = repeats
    }

    private enum CodingKeys: String, CodingKey { case id, symbol, condition, note, repeats, triggeredAt, createdAt, target, above }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        symbol = try c.decode(String.self, forKey: .symbol)
        if let condition = try c.decodeIfPresent(AlertCondition.self, forKey: .condition) {
            self.condition = condition
        } else {
            // v1/v2: { target, above }
            let target = try c.decode(Decimal.self, forKey: .target)
            condition = try c.decode(Bool.self, forKey: .above) ? .priceAbove(target) : .priceBelow(target)
        }
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        repeats = try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? false
        triggeredAt = try c.decodeIfPresent(Date.self, forKey: .triggeredAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(symbol, forKey: .symbol); try c.encode(condition, forKey: .condition)
        try c.encode(note, forKey: .note); try c.encode(repeats, forKey: .repeats)
        try c.encodeIfPresent(triggeredAt, forKey: .triggeredAt); try c.encode(createdAt, forKey: .createdAt)
    }
}

nonisolated struct ReplayResult: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var scenario: String
    var choice: String
    var reason: String
    var outcome: Double
    var reflection: String
    var date = Date()
}

nonisolated enum TodaySection: String, Codable, CaseIterable, Sendable {
    case watchlists = "Watchlists", learning = "Learning", events = "Events"
}

nonisolated struct UserFeatures: Codable, Hashable, Sendable {
    var watchlists: [NamedWatchlist] = []
    var tradeNotes: [String: TradeNote] = [:]
    var research: [SavedResearch] = []
    var recurring: [ScheduledInvestment] = []
    var events: [TrackedEvent] = []
    var alerts: [PriceAlert] = []
    var replays: [ReplayResult] = []
    var completedBites: [String] = []
    var guidedSteps: [String] = []
    var todaySections: [TodaySection] = TodaySection.allCases
    var drawings: [ChartDrawing] = []
    var chart = ChartPreferences()
    var barReplays: [BarReplayRecord] = []
    var learning = LearningState()

    init() {}
    private enum CodingKeys: String, CodingKey {
        case watchlists, tradeNotes, research, recurring, events, alerts, replays, completedBites, guidedSteps, todaySections
        case drawings, chart, barReplays, learning
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchlists = (try? c.decodeIfPresent([NamedWatchlist].self, forKey: .watchlists)) ?? []
        tradeNotes = (try? c.decodeIfPresent([String: TradeNote].self, forKey: .tradeNotes)) ?? [:]
        research = (try? c.decodeIfPresent([SavedResearch].self, forKey: .research)) ?? []
        recurring = (try? c.decodeIfPresent([ScheduledInvestment].self, forKey: .recurring)) ?? []
        events = (try? c.decodeIfPresent([TrackedEvent].self, forKey: .events)) ?? []
        alerts = (try? c.decodeIfPresent([PriceAlert].self, forKey: .alerts)) ?? []
        replays = (try? c.decodeIfPresent([ReplayResult].self, forKey: .replays)) ?? []
        completedBites = (try? c.decodeIfPresent([String].self, forKey: .completedBites)) ?? []
        guidedSteps = (try? c.decodeIfPresent([String].self, forKey: .guidedSteps)) ?? []
        let sections = (try? c.decodeIfPresent([String].self, forKey: .todaySections)) ?? TodaySection.allCases.map(\.rawValue)
        todaySections = sections.compactMap(TodaySection.init(rawValue:))
        drawings = (try? c.decodeIfPresent([ChartDrawing].self, forKey: .drawings)) ?? []
        chart = (try? c.decodeIfPresent(ChartPreferences.self, forKey: .chart)) ?? ChartPreferences()
        barReplays = (try? c.decodeIfPresent([BarReplayRecord].self, forKey: .barReplays)) ?? []
        learning = (try? c.decodeIfPresent(LearningState.self, forKey: .learning)) ?? LearningState()
    }
}

/// Everything the app persists and syncs, in one value.
nonisolated struct Workspace: Codable, Hashable, Sendable {
    static let currentVersion = 4
    var schemaVersion = Workspace.currentVersion
    var portfolios: [Portfolio]
    /// Device-local choice; never taken from a remote copy.
    var activePortfolioID: String
    var features = UserFeatures()
    var customSecurities: [Security] = []
    /// "kind:id" → deletion time, so a merge does not resurrect something deleted on another device.
    var tombstones: [String: Date] = [:]

    static func fresh(name: String = "") -> Workspace {
        Workspace(portfolios: [Portfolio(id: Portfolio.primaryID, title: "Main portfolio", account: AccountData(name: name))],
                  activePortfolioID: Portfolio.primaryID)
    }

    var activeIndex: Int { portfolios.firstIndex { $0.id == activePortfolioID } ?? 0 }

    /// Drops journal notes whose orders no longer exist anywhere.
    mutating func pruneOrphans() {
        let orderIDs = Set(portfolios.flatMap { $0.account.orders.map(\.id.uuidString) })
        features.tradeNotes = features.tradeNotes.filter { orderIDs.contains($0.key) }
        let portfolioIDs = Set(portfolios.map(\.id))
        features.recurring.removeAll { !portfolioIDs.contains($0.portfolio) }
        let symbols = Set(MarketCatalog.securities.map(\.symbol) + customSecurities.map(\.symbol))
        features.watchlists = features.watchlists.map { list in
            var list = list
            list.symbols.removeAll { !symbols.contains($0) }
            let kept = Set(list.symbols)
            list.pinned.removeAll { !kept.contains($0) }
            return list
        }
        features.drawings.removeAll { !symbols.contains($0.symbol) }
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        tombstones = tombstones.filter { $0.value > cutoff }
    }
}
