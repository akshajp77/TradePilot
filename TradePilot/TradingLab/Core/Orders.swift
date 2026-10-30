import Foundation

nonisolated enum OrderSide: String, Codable, CaseIterable, Sendable {
    case buy = "Buy", sell = "Sell"
    var sign: Decimal { self == .buy ? 1 : -1 }
    var opposite: OrderSide { self == .buy ? .sell : .buy }
}

nonisolated enum OrderType: String, Codable, CaseIterable, Sendable {
    case market = "Market"
    case limit = "Limit"
    /// Becomes a market order when the last price trades through `stop`.
    case stop = "Stop"
    /// Becomes a limit order at `limit` when the last price trades through `stop`.
    case stopLimit = "Stop limit"
    /// A stop that follows the best price by `trailAmount` dollars or `trailPercent`.
    case trailingStop = "Trailing stop"

    var usesLimit: Bool { self == .limit || self == .stopLimit }
    var usesStop: Bool { self == .stop || self == .stopLimit }
    var isStopFamily: Bool { self == .stop || self == .stopLimit || self == .trailingStop }
}

nonisolated enum TimeInForce: String, Codable, CaseIterable, Sendable {
    /// Expires at the end of the session it was placed for.
    case day = "Day"
    /// Good 'til canceled.
    case gtc = "GTC"
}

nonisolated enum OrderRole: String, Codable, Sendable {
    case entry = "Entry"
    case takeProfit = "Take profit"
    case stopLoss = "Stop loss"
    /// Manual close / flatten.
    case exit = "Exit"
}

nonisolated enum OrderStatus: String, Codable, Sendable {
    /// Bracket child waiting for its parent to fill.
    case held = "Held"
    /// Market order placed while the market was closed; fills at the first in-session price.
    case queued = "Queued"
    /// Working: limit, stop or trailing order waiting for its price.
    case open = "Open"
    case filled = "Filled"
    case canceled = "Canceled"
    case expired = "Expired"
    var isPending: Bool { self == .held || self == .queued || self == .open }
    var isWorking: Bool { self == .queued || self == .open }
    var isFinal: Bool { !isPending }
}

nonisolated struct PracticeOrder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let symbol: String
    let side: OrderSide
    var shares: Decimal
    let type: OrderType
    var limit: Decimal?
    var stop: Decimal?
    var trailAmount: Decimal?
    var trailPercent: Decimal?
    /// Best price seen since activation (high for sell trails, low for buy trails).
    var trailAnchor: Decimal?
    var tif: TimeInForce
    var extendedHours: Bool
    var expiresAt: Date?
    var role: OrderRole
    /// Bracket parent; children stay `held` until it fills.
    var parentID: UUID?
    /// Orders sharing an OCO group cancel each other when one fills.
    var ocoID: UUID?
    /// May only reduce an existing position; canceled if the position is gone.
    var reduceOnly: Bool
    /// The stop the trader planned at entry, used for R-multiples and risk checks.
    var plannedStop: Decimal?
    var plannedTarget: Decimal?
    let submittedAt: Date
    /// When the order began reacting to prices (submission, or the parent's fill for bracket children).
    var activatedAt: Date?
    var status: OrderStatus
    var triggeredAt: Date?
    var fillPrice: Decimal?
    var filledAt: Date?
    var fees: Decimal
    /// Price seen at submission; reserves buying power for queued and stop orders.
    var reference: Decimal?
    var statusNote: String?
    let thesis: String
    let invalidation: String
    let horizon: String
    var reflection: String
    var updatedAt: Date

    init(id: UUID = UUID(), symbol: String, side: OrderSide, shares: Decimal, type: OrderType, limit: Decimal? = nil,
         stop: Decimal? = nil, trailAmount: Decimal? = nil, trailPercent: Decimal? = nil, tif: TimeInForce = .day,
         extendedHours: Bool = false, role: OrderRole = .entry, parentID: UUID? = nil, ocoID: UUID? = nil,
         reduceOnly: Bool = false, plannedStop: Decimal? = nil, plannedTarget: Decimal? = nil,
         submittedAt: Date, status: OrderStatus, fillPrice: Decimal? = nil, filledAt: Date? = nil, fees: Decimal = 0,
         reference: Decimal? = nil, statusNote: String? = nil, thesis: String = "", invalidation: String = "",
         horizon: String = "", reflection: String = "") {
        self.id = id; self.symbol = symbol; self.side = side; self.shares = shares; self.type = type
        self.limit = limit; self.stop = stop; self.trailAmount = trailAmount; self.trailPercent = trailPercent
        self.tif = tif; self.extendedHours = extendedHours; self.role = role; self.parentID = parentID; self.ocoID = ocoID
        self.reduceOnly = reduceOnly; self.plannedStop = plannedStop; self.plannedTarget = plannedTarget
        self.submittedAt = submittedAt; self.activatedAt = parentID == nil ? submittedAt : nil
        self.status = status; self.fillPrice = fillPrice; self.filledAt = filledAt; self.fees = fees
        self.reference = reference; self.statusNote = statusNote; self.thesis = thesis
        self.invalidation = invalidation; self.horizon = horizon; self.reflection = reflection
        self.updatedAt = filledAt ?? submittedAt
    }

    /// The price a stop or trailing stop triggers at right now.
    var effectiveStop: Decimal? {
        switch type {
        case .stop, .stopLimit: return stop
        case .trailingStop:
            guard let anchor = trailAnchor else { return stop }
            if let amount = trailAmount { return side == .sell ? anchor - amount : anchor + amount }
            if let percent = trailPercent { return (side == .sell ? anchor * (1 - percent) : anchor * (1 + percent)).rounded(Precision.price) }
            return stop
        default: return nil
        }
    }

    /// Short human description, e.g. "Buy 10 AAPL · Stop limit 101.00 / 101.50".
    var summary: String {
        var parts = "\(side.rawValue) \(Format.shares(shares)) \(symbol) · \(type.rawValue)"
        switch type {
        case .market: break
        case .limit: parts += " \(Format.plain(limit))"
        case .stop: parts += " \(Format.plain(stop))"
        case .stopLimit: parts += " \(Format.plain(stop)) / \(Format.plain(limit))"
        case .trailingStop:
            if let amount = trailAmount { parts += " $\(Format.plain(amount)) trail" }
            else if let percent = trailPercent { parts += " \(Format.plain(percent * 100))% trail" }
        }
        return parts
    }

    private enum CodingKeys: String, CodingKey {
        case id, symbol, side, shares, type, limit, stop, trailAmount, trailPercent, trailAnchor, tif, extendedHours, expiresAt
        case role, parentID, ocoID, reduceOnly, plannedStop, plannedTarget, submittedAt, activatedAt, status, triggeredAt
        case fillPrice, filledAt, fees, reference, statusNote, thesis, invalidation, horizon, reflection, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        symbol = try c.decode(String.self, forKey: .symbol)
        side = try c.decode(OrderSide.self, forKey: .side)
        // v1 stored Double; trim the float noise once on the way in.
        shares = try c.decode(Decimal.self, forKey: .shares).rounded(Precision.shares)
        type = try c.decode(OrderType.self, forKey: .type)
        limit = try c.decodeIfPresent(Decimal.self, forKey: .limit)?.rounded(Precision.price)
        stop = try c.decodeIfPresent(Decimal.self, forKey: .stop)?.rounded(Precision.price)
        trailAmount = try c.decodeIfPresent(Decimal.self, forKey: .trailAmount)
        trailPercent = try c.decodeIfPresent(Decimal.self, forKey: .trailPercent)
        trailAnchor = try c.decodeIfPresent(Decimal.self, forKey: .trailAnchor)
        tif = try c.decodeIfPresent(TimeInForce.self, forKey: .tif) ?? .gtc // v1/v2 orders never expired
        extendedHours = try c.decodeIfPresent(Bool.self, forKey: .extendedHours) ?? false
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        role = try c.decodeIfPresent(OrderRole.self, forKey: .role) ?? .entry
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        ocoID = try c.decodeIfPresent(UUID.self, forKey: .ocoID)
        reduceOnly = try c.decodeIfPresent(Bool.self, forKey: .reduceOnly) ?? false
        plannedStop = try c.decodeIfPresent(Decimal.self, forKey: .plannedStop)
        plannedTarget = try c.decodeIfPresent(Decimal.self, forKey: .plannedTarget)
        submittedAt = try c.decode(Date.self, forKey: .submittedAt)
        activatedAt = try c.decodeIfPresent(Date.self, forKey: .activatedAt) ?? (parentID == nil ? submittedAt : nil)
        status = try c.decode(OrderStatus.self, forKey: .status)
        triggeredAt = try c.decodeIfPresent(Date.self, forKey: .triggeredAt)
        fillPrice = try c.decodeIfPresent(Decimal.self, forKey: .fillPrice)?.rounded(Precision.price)
        filledAt = try c.decodeIfPresent(Date.self, forKey: .filledAt)
        fees = try c.decodeIfPresent(Decimal.self, forKey: .fees) ?? 0
        reference = try c.decodeIfPresent(Decimal.self, forKey: .reference)
        statusNote = try c.decodeIfPresent(String.self, forKey: .statusNote)
        thesis = try c.decodeIfPresent(String.self, forKey: .thesis) ?? ""
        invalidation = try c.decodeIfPresent(String.self, forKey: .invalidation) ?? ""
        horizon = try c.decodeIfPresent(String.self, forKey: .horizon) ?? ""
        reflection = try c.decodeIfPresent(String.self, forKey: .reflection) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? filledAt ?? submittedAt
    }
}

// MARK: - Account rules

nonisolated enum AccountType: String, Codable, CaseIterable, Sendable {
    case cash = "Cash"
    case margin = "Margin"
}

nonisolated enum MarginRegime: String, Codable, CaseIterable, Sendable {
    /// FINRA Rule 4210 as amended (effective June 4, 2026): no PDT designation, no $25,000 minimum;
    /// maintenance margin is checked intraday and trades that would create a deficit are blocked.
    case intraday2026 = "Intraday margin (2026)"
    /// The pre-2026 pattern day trader rule, which some brokers apply until October 20, 2027.
    case legacyPDT = "Legacy PDT rule"
}

nonisolated enum FillModel: String, Codable, CaseIterable, Sendable {
    /// Buys pay the ask, sells receive the bid, and market orders pay slippage.
    case realistic = "Realistic"
    /// Fills at the last trade price. Optimistic; useful to isolate decision quality.
    case ideal = "Last price"
}

nonisolated struct TradingSettings: Codable, Hashable, Sendable {
    static let marginMinimumEquity: Decimal = 2_000
    static let legacyPDTEquity: Decimal = 25_000
    static let regTInitial: Decimal = Decimal(string: "0.5")!

    var accountType: AccountType = .margin
    var shortingEnabled = true
    var regime: MarginRegime = .intraday2026
    /// House maintenance requirement on long and short market value (FINRA minimum 25%; brokers often 30–40%).
    var maintenanceRate: Decimal = Decimal(string: "0.30")!
    var fillModel: FillModel = .realistic
    /// Market and stop order slippage, in basis points of price.
    var slippageBps: Decimal = 2
    var commissionPerOrder: Decimal = 0
    var commissionPerShare: Decimal = 0
    /// Locks new positions for the rest of the session once today's P&L reaches −limit.
    var dailyLossLimit: Decimal?
    /// Largest single position as a fraction of equity (0.25 = 25%).
    var maxPositionFraction: Decimal?
    /// Reject entries without a stop (bracket stop loss or planned stop).
    var requireStop = false
    var confirmOrders = true
    /// Default risk per trade for the position-size calculator (0.01 = 1% of equity).
    var riskFraction: Decimal = Decimal(string: "0.01")!

    init() {}

    private enum CodingKeys: String, CodingKey {
        case accountType, shortingEnabled, regime, maintenanceRate, fillModel, slippageBps, commissionPerOrder, commissionPerShare
        case dailyLossLimit, maxPositionFraction, requireStop, confirmOrders, riskFraction
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TradingSettings()
        accountType = (try? c.decodeIfPresent(AccountType.self, forKey: .accountType)) ?? d.accountType
        shortingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .shortingEnabled)) ?? d.shortingEnabled
        regime = (try? c.decodeIfPresent(MarginRegime.self, forKey: .regime)) ?? d.regime
        maintenanceRate = (try? c.decodeIfPresent(Decimal.self, forKey: .maintenanceRate)) ?? d.maintenanceRate
        fillModel = (try? c.decodeIfPresent(FillModel.self, forKey: .fillModel)) ?? d.fillModel
        slippageBps = (try? c.decodeIfPresent(Decimal.self, forKey: .slippageBps)) ?? d.slippageBps
        commissionPerOrder = (try? c.decodeIfPresent(Decimal.self, forKey: .commissionPerOrder)) ?? 0
        commissionPerShare = (try? c.decodeIfPresent(Decimal.self, forKey: .commissionPerShare)) ?? 0
        dailyLossLimit = try? c.decodeIfPresent(Decimal.self, forKey: .dailyLossLimit)
        maxPositionFraction = try? c.decodeIfPresent(Decimal.self, forKey: .maxPositionFraction)
        requireStop = (try? c.decodeIfPresent(Bool.self, forKey: .requireStop)) ?? false
        confirmOrders = (try? c.decodeIfPresent(Bool.self, forKey: .confirmOrders)) ?? true
        riskFraction = (try? c.decodeIfPresent(Decimal.self, forKey: .riskFraction)) ?? d.riskFraction
    }

    var canShort: Bool { accountType == .margin && shortingEnabled }

    func fees(shares: Decimal) -> Decimal {
        (commissionPerOrder + commissionPerShare * shares).rounded(Precision.cash)
    }
}
