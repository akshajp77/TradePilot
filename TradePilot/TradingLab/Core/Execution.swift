import Foundation

nonisolated enum OrderRejection: Error, Equatable, Sendable {
    case notTradable
    case invalidQuantity
    case invalidLimit
    case invalidStop
    case invalidTrail
    case noPrice
    case extendedHoursNeedsLimit
    case stopOnWrongSide(String)
    case bracketInvalid(String)
    case insufficientShares(available: Decimal)
    case shortingNotAllowed(String)
    case insufficientBuyingPower(available: Decimal)
    case marginDeficit(requirement: Decimal, equity: Decimal)
    case pdtProtection(dayTrades: Int)
    case dailyLossLimit(Decimal)
    case positionTooLarge(Decimal)
    case stopRequired
    case reduceOnlyWouldOpen

    var message: String {
        switch self {
        case .notTradable: return "Choose a tradable stock or ETF. Indexes can be watched, not traded."
        case .invalidQuantity: return "Enter an amount above zero. Fractional shares go to six decimal places."
        case .invalidLimit: return "Enter a positive limit price."
        case .invalidStop: return "Enter a positive stop price."
        case .invalidTrail: return "Enter a trailing amount in dollars or a percent below 100%."
        case .noPrice: return "A price from the last week is needed. Pull to refresh."
        case .extendedHoursNeedsLimit: return "Pre-market and after-hours orders must be limit orders."
        case .stopOnWrongSide(let detail): return detail
        case .bracketInvalid(let detail): return detail
        case .insufficientShares(let available): return "You can sell at most \(Format.shares(available)) shares. Shorting needs a margin account with shorting on."
        case .shortingNotAllowed(let detail): return detail
        case .insufficientBuyingPower(let available): return "Not enough buying power. Available: \(Format.money(available))."
        case .marginDeficit(let requirement, let equity):
            return "This trade would create an intraday margin deficit: equity \(Format.money(equity)) below the \(Format.money(requirement)) maintenance requirement."
        case .pdtProtection(let count):
            return "Pattern day trader protection (legacy rule): you have made \(count) day trades in 5 business days with under $25,000 equity. Closing this same-day position would be another. Hold it overnight or switch to the 2026 intraday-margin rules in Settings."
        case .dailyLossLimit(let limit): return "Daily loss limit of \(Format.money(limit)) reached. You can reduce or close positions until the next session."
        case .positionTooLarge(let fraction): return "This would make the position larger than your \(Format.percent(fraction.double, digits: 0).replacingOccurrences(of: "+", with: "")) limit."
        case .stopRequired: return "Your rules require a stop. Add a stop loss to this entry."
        case .reduceOnlyWouldOpen: return "This exit would open a new position. Reduce the quantity."
        }
    }
}

/// What the trader asked for, before validation.
nonisolated struct OrderRequest: Sendable {
    var symbol: String
    var side: OrderSide
    var shares: Decimal
    var type: OrderType
    var limit: Decimal? = nil
    var stop: Decimal? = nil
    var trailAmount: Decimal? = nil
    var trailPercent: Decimal? = nil
    var tif: TimeInForce = .day
    var extendedHours = false
    /// Bracket legs: a take-profit limit and a stop-loss stop, OCO, active once the entry fills.
    var takeProfit: Decimal? = nil
    var stopLoss: Decimal? = nil
    /// Planned stop for risk and R-multiples when no bracket stop is attached.
    var plannedStop: Decimal? = nil
    var reduceOnly = false
    var role: OrderRole = .entry
    var thesis = ""
    var invalidation = ""
    var horizon = ""
}

/// Everything the engine needs to know about the market that is not in the account.
nonisolated struct MarketContext {
    var price: (String) -> Decimal?
    /// Today's account P&L, for the daily loss limit.
    var dayPnL: Decimal?
    var now: Date
    var hours: MarketHours = .nyse
}

nonisolated enum OrderEvent: Sendable, Equatable {
    case filled(PracticeOrder)
    case triggered(PracticeOrder)
    case canceled(PracticeOrder, reason: String)
    case expired(PracticeOrder)
    case activated(PracticeOrder)

    var order: PracticeOrder {
        switch self {
        case .filled(let o), .triggered(let o), .expired(let o), .activated(let o): return o
        case .canceled(let o, _): return o
        }
    }
}

nonisolated enum OrderEngine {
    static let maxReferenceAge: TimeInterval = 7 * 86_400

    static func maxLiveAge(_ source: QuoteSource) -> TimeInterval {
        switch source {
        case .iexTrade: return 120
        case .delayed: return 20 * 60
        case .dailyClose: return 0
        case .replay: return .infinity
        }
    }

    /// A quote good enough to act on now: from the current session window and recent.
    static func isFresh(_ quote: Quote, now: Date, hours: MarketHours = .nyse) -> Bool {
        guard hours.sessionKind(at: now) != .closed, hours.sessionKind(at: quote.time) != .closed,
              hours.isSameSessionDay(quote.time, now), quote.time <= now.addingTimeInterval(1) else { return false }
        return now.timeIntervalSince(quote.time) <= maxLiveAge(quote.source)
    }

    // MARK: Fill prices

    static func halfSpread(_ price: Decimal) -> Decimal {
        max(Decimal(string: "0.005")!, (price * Decimal(string: "0.0001")!).rounded(Precision.price))
    }

    static func ask(_ quote: Quote, _ settings: TradingSettings) -> Decimal {
        settings.fillModel == .ideal ? quote.price : (quote.ask ?? quote.price + halfSpread(quote.price))
    }

    static func bid(_ quote: Quote, _ settings: TradingSettings) -> Decimal {
        settings.fillModel == .ideal ? quote.price : (quote.bid ?? quote.price - halfSpread(quote.price))
    }

    /// Market and triggered-stop fills: the far side of the spread plus slippage.
    static func marketFill(side: OrderSide, quote: Quote, settings: TradingSettings) -> Decimal {
        if settings.fillModel == .ideal { return quote.price.tickRounded }
        let base = side == .buy ? ask(quote, settings) : bid(quote, settings)
        let slip = base * settings.slippageBps / 10_000
        return max(Decimal(string: "0.0001")!, (side == .buy ? base + slip : base - slip).tickRounded)
    }

    // MARK: Submit

    /// Validates and records an order (plus bracket legs). If the quote is fresh, the order is
    /// evaluated immediately; otherwise it waits for the next eligible price.
    static func submit(_ request: OrderRequest, kind: SecurityKind?, account: inout AccountData, quote: Quote?,
                       context: MarketContext) -> Result<PracticeOrder, OrderRejection> {
        let now = context.now, hours = context.hours, settings = account.settings
        guard let kind, kind.tradable else { return .failure(.notTradable) }
        let shares = request.shares.rounded(Precision.shares, .down)
        guard shares > 0 else { return .failure(.invalidQuantity) }
        let limit = request.limit?.rounded(Precision.price), stop = request.stop?.rounded(Precision.price)
        if request.type.usesLimit { guard let limit, limit > 0 else { return .failure(.invalidLimit) } }
        if request.type.usesStop { guard let stop, stop > 0 else { return .failure(.invalidStop) } }
        if request.type == .trailingStop {
            let amountOK = (request.trailAmount ?? 0) > 0, percentOK = (request.trailPercent ?? 0) > 0 && (request.trailPercent ?? 1) < 1
            guard amountOK != percentOK else { return .failure(.invalidTrail) }
        }
        guard let quote, quote.price > 0, now.timeIntervalSince(quote.time) <= maxReferenceAge else { return .failure(.noPrice) }
        if request.extendedHours && request.type != .limit { return .failure(.extendedHoursNeedsLimit) }
        let reference = quote.price

        if request.type.usesStop, let stop {
            if request.side == .buy && stop <= reference {
                return .failure(.stopOnWrongSide("A buy stop must be above the current price (\(Format.money(reference))). Use a limit to buy lower."))
            }
            if request.side == .sell && stop >= reference {
                return .failure(.stopOnWrongSide("A sell stop must be below the current price (\(Format.money(reference))). Use a limit to sell higher."))
            }
        }

        let entryPrice = limit ?? stop ?? reference
        let tp = request.takeProfit?.rounded(Precision.price), sl = request.stopLoss?.rounded(Precision.price)
        if let tp {
            guard tp > 0, request.side == .buy ? tp > entryPrice : tp < entryPrice else {
                return .failure(.bracketInvalid(request.side == .buy ? "Take profit must be above the entry price." : "Take profit must be below the entry price for a short."))
            }
        }
        if let sl {
            guard sl > 0, request.side == .buy ? sl < entryPrice : sl > entryPrice else {
                return .failure(.bracketInvalid(request.side == .buy ? "Stop loss must be below the entry price." : "Stop loss must be above the entry price for a short."))
            }
        }

        let ledger = Ledger(account, hours: hours)
        let position = ledger.shares(request.symbol)
        let split = Ledger.split(side: request.side, shares: shares, position: position)
        let snapshot = Margin.snapshot(account: account, ledger: ledger, price: { context.price($0) ?? ($0 == request.symbol ? reference : nil) }, now: now)

        if request.reduceOnly && split.opening > 0 { return .failure(.reduceOnlyWouldOpen) }

        // Selling beyond the long position: available shares, then shorting rules.
        if request.side == .sell && split.opening > 0 {
            let pendingSells = ledger.pending.filter { $0.symbol == request.symbol && $0.side == .sell && $0.status.isWorking && $0.parentID == nil }
                .reduce(Decimal(0)) { $0 + $1.shares }
            let availableLong = max(0, position - pendingSells)
            if !settings.canShort {
                return .failure(settings.accountType == .cash ? .insufficientShares(available: availableLong) : .shortingNotAllowed("Shorting is off for this portfolio. Turn it on in Settings → Trading."))
            }
            if let snapshot, !snapshot.leverage {
                return .failure(.shortingNotAllowed("Short selling needs at least \(Format.money(TradingSettings.marginMinimumEquity)) in equity."))
            }
        }

        if split.opening > 0, let snapshot {
            let fees = settings.fees(shares: shares)
            let required = Decimal.notional(split.opening, entryPrice) + fees
            if required > snapshot.availableBuyingPower { return .failure(.insufficientBuyingPower(available: snapshot.availableBuyingPower)) }

            // Intraday margin (2026 rule): maintenance is checked as if the trade filled now.
            if settings.accountType == .margin {
                let signed = request.side.sign * shares
                let newPosition = position + signed
                let otherExposure = snapshot.longValue + snapshot.shortValue - (abs(position) * reference).rounded(Precision.cash)
                let gross = otherExposure + (abs(newPosition) * reference).rounded(Precision.cash)
                let equityAfter = snapshot.equity - fees - (signed * (entryPrice - reference)).rounded(Precision.cash)
                let requirement = (gross * settings.maintenanceRate).rounded(Precision.cash)
                if equityAfter < requirement { return .failure(.marginDeficit(requirement: requirement, equity: equityAfter)) }
            }

            if let limitLoss = settings.dailyLossLimit, limitLoss > 0, let day = context.dayPnL, day <= -limitLoss {
                return .failure(.dailyLossLimit(limitLoss))
            }
            if let fraction = settings.maxPositionFraction, fraction > 0, snapshot.equity > 0 {
                let after = abs(position + request.side.sign * shares) * entryPrice
                if after / snapshot.equity > fraction { return .failure(.positionTooLarge(fraction)) }
            }
            if settings.requireStop && request.role == .entry && sl == nil && request.plannedStop == nil && !request.type.isStopFamily {
                return .failure(.stopRequired)
            }
        }

        // Legacy PDT protection: block the 4th day trade in 5 sessions under $25,000.
        if settings.regime == .legacyPDT && settings.accountType == .margin && split.closing > 0,
           let opened = ledger.position(request.symbol)?.openedAt, hours.isSameSessionDay(opened, now),
           (snapshot?.equity ?? 0) < TradingSettings.legacyPDTEquity {
            let count = ledger.dayTradeCount(asOf: now)
            if count >= 3 { return .failure(.pdtProtection(dayTrades: count)) }
        }

        // Build the order and any bracket legs.
        let expires = request.tif == .day ? hours.dayOrderExpiry(placedAt: now, extendedHours: request.extendedHours) : nil
        var entry = PracticeOrder(symbol: request.symbol, side: request.side, shares: shares, type: request.type,
                                  limit: request.type.usesLimit ? limit : nil, stop: request.type.usesStop ? stop : nil,
                                  trailAmount: request.type == .trailingStop ? request.trailAmount : nil,
                                  trailPercent: request.type == .trailingStop ? request.trailPercent : nil,
                                  tif: request.tif, extendedHours: request.extendedHours, role: request.role,
                                  reduceOnly: request.reduceOnly, plannedStop: sl ?? request.plannedStop, plannedTarget: tp,
                                  submittedAt: now, status: request.type == .market ? .queued : .open,
                                  fees: 0, reference: reference, thesis: request.thesis, invalidation: request.invalidation, horizon: request.horizon)
        entry.expiresAt = expires
        if request.type == .trailingStop { entry.trailAnchor = reference }
        if request.type == .market && !hours.isOpen(at: now) { entry.statusNote = "Queued for the next market open" }

        var legs: [PracticeOrder] = []
        if tp != nil || sl != nil {
            let group = UUID()
            if let tp {
                var leg = PracticeOrder(symbol: request.symbol, side: request.side.opposite, shares: shares, type: .limit, limit: tp,
                                        tif: request.tif, role: .takeProfit, parentID: entry.id, ocoID: sl != nil ? group : nil,
                                        reduceOnly: true, submittedAt: now, status: .held, reference: reference)
                leg.statusNote = "Active when the entry fills"
                legs.append(leg)
            }
            if let sl {
                var leg = PracticeOrder(symbol: request.symbol, side: request.side.opposite, shares: shares, type: .stop, stop: sl,
                                        tif: request.tif, role: .stopLoss, parentID: entry.id, ocoID: tp != nil ? group : nil,
                                        reduceOnly: true, submittedAt: now, status: .held, reference: reference)
                leg.statusNote = "Active when the entry fills"
                legs.append(leg)
            }
        }
        account.orders.insert(contentsOf: [entry] + legs, at: 0)

        if isFresh(quote, now: now, hours: hours) {
            _ = process(symbol: request.symbol, quote: quote.at(now), account: &account, context: context)
        }
        let recorded = account.orders.first { $0.id == entry.id } ?? entry
        return .success(recorded)
    }

    // MARK: Process prices

    /// Applies a price print to working orders for `symbol`. Returns what happened, in order.
    @discardableResult
    static func process(symbol: String, quote: Quote, account: inout AccountData, context: MarketContext) -> [OrderEvent] {
        let hours = context.hours, settings = account.settings, time = quote.time
        let session = hours.sessionKind(at: time)
        guard session != .closed else { return [] }
        var events: [OrderEvent] = []
        let candidates = account.orders.indices
            .filter { account.orders[$0].symbol == symbol && account.orders[$0].status.isWorking }
            .sorted { (account.orders[$0].activatedAt ?? account.orders[$0].submittedAt) < (account.orders[$1].activatedAt ?? account.orders[$1].submittedAt) }
            .map { account.orders[$0].id }

        for id in candidates {
            guard let i = account.orders.firstIndex(where: { $0.id == id }), account.orders[i].status.isWorking else { continue }
            var order = account.orders[i]
            guard let activated = order.activatedAt, time >= activated else { continue }
            if let expiry = order.expiresAt, time >= expiry {
                order.status = .expired; order.statusNote = "Expired at the end of the session"; order.updatedAt = time
                account.orders[i] = order
                events.append(.expired(order))
                cancelChildren(of: order.id, in: &account, reason: "Parent order expired", time: time, events: &events)
                continue
            }
            // Session eligibility: extended hours are for limit orders that opted in; stops trigger in regular hours only.
            if session != .regular && !(order.extendedHours && order.type == .limit) { continue }

            let price = quote.price
            if order.type == .trailingStop {
                let anchor = order.trailAnchor ?? price
                order.trailAnchor = order.side == .sell ? max(anchor, price) : min(anchor, price)
            }
            if order.type.isStopFamily && order.triggeredAt == nil {
                guard let stopPrice = order.effectiveStop else { continue }
                let hit = order.side == .buy ? price >= stopPrice : price <= stopPrice
                guard hit else { account.orders[i] = order; continue }
                order.triggeredAt = time
                order.statusNote = "Triggered at \(Format.money(price))"
                events.append(.triggered(order))
            }

            // Price for the fill, if any.
            var fill: Decimal?
            switch order.type {
            case .market, .stop, .trailingStop:
                fill = marketFill(side: order.side, quote: quote, settings: settings)
            case .limit, .stopLimit:
                guard let limit = order.limit else { break }
                if order.side == .buy {
                    let a = ask(quote, settings)
                    if a <= limit { fill = min(limit, a).tickRounded }
                } else {
                    let b = bid(quote, settings)
                    if b >= limit { fill = max(limit, b).tickRounded }
                }
            }
            guard let fillPrice = fill else { account.orders[i] = order; continue }

            // Reduce-only exits shrink or cancel when the position is smaller than the order.
            let ledger = Ledger(account, hours: hours)
            let position = ledger.shares(symbol)
            if order.reduceOnly {
                let closable = Ledger.split(side: order.side, shares: order.shares, position: position).closing
                if closable == 0 {
                    order.status = .canceled; order.statusNote = "Canceled: no position left to close"; order.updatedAt = time
                    account.orders[i] = order
                    events.append(.canceled(order, reason: "No position left to close"))
                    continue
                }
                order.shares = closable
            }
            // Market-like orders re-check buying power at the fill price (gaps).
            if !order.type.usesLimit && !order.reduceOnly {
                let split = Ledger.split(side: order.side, shares: order.shares, position: position)
                if split.opening > 0, let snapshot = Margin.snapshot(account: account, ledger: ledger,
                                                                      price: { context.price($0) ?? ($0 == symbol ? quote.price : nil) }, now: time) {
                    let own = Margin.reservation(order, position: position, settings: settings)
                    let available = snapshot.availableBuyingPower + own
                    let required = Decimal.notional(split.opening, fillPrice) + settings.fees(shares: order.shares)
                    if required > available {
                        order.status = .canceled
                        order.statusNote = order.side == .buy ? "Canceled: the price moved beyond your buying power" : "Canceled: not enough buying power to short at this price"
                        order.updatedAt = time
                        account.orders[i] = order
                        events.append(.canceled(order, reason: order.statusNote ?? ""))
                        cancelChildren(of: order.id, in: &account, reason: "Entry canceled", time: time, events: &events)
                        continue
                    }
                }
            }

            order.status = .filled
            order.fillPrice = fillPrice
            order.filledAt = time
            order.fees = settings.fees(shares: order.shares)
            order.statusNote = nil
            order.updatedAt = time
            account.orders[i] = order
            events.append(.filled(order))

            // Bracket children go live; OCO siblings cancel.
            for j in account.orders.indices where account.orders[j].parentID == order.id && account.orders[j].status == .held {
                account.orders[j].status = .open
                account.orders[j].activatedAt = time
                account.orders[j].statusNote = nil
                if account.orders[j].tif == .day { account.orders[j].expiresAt = hours.dayOrderExpiry(placedAt: time, extendedHours: false) }
                if account.orders[j].type == .trailingStop { account.orders[j].trailAnchor = fillPrice }
                account.orders[j].shares = min(account.orders[j].shares, order.shares)
                account.orders[j].updatedAt = time
                events.append(.activated(account.orders[j]))
            }
            if let group = order.ocoID {
                for j in account.orders.indices where account.orders[j].ocoID == group && account.orders[j].id != order.id && account.orders[j].status.isPending {
                    account.orders[j].status = .canceled
                    account.orders[j].statusNote = "Canceled: other side of the bracket filled"
                    account.orders[j].updatedAt = time
                    events.append(.canceled(account.orders[j], reason: "OCO"))
                }
            }
        }
        cleanUpExits(symbol: symbol, account: &account, time: time, events: &events)
        return events
    }

    /// Cancels working reduce-only exits once their position is flat (closed manually or by another exit).
    static func cleanUpExits(symbol: String, account: inout AccountData, time: Date, events: inout [OrderEvent]) {
        let position = Ledger(account).shares(symbol)
        for j in account.orders.indices where account.orders[j].symbol == symbol && account.orders[j].reduceOnly && account.orders[j].status == .open {
            let order = account.orders[j]
            if Ledger.split(side: order.side, shares: order.shares, position: position).closing == 0 {
                account.orders[j].status = .canceled
                account.orders[j].statusNote = "Canceled: position closed"
                account.orders[j].updatedAt = time
                events.append(.canceled(account.orders[j], reason: "Position closed"))
            }
        }
    }

    private static func cancelChildren(of id: UUID, in account: inout AccountData, reason: String, time: Date, events: inout [OrderEvent]) {
        for j in account.orders.indices where account.orders[j].parentID == id && account.orders[j].status.isPending {
            account.orders[j].status = .canceled
            account.orders[j].statusNote = "Canceled: \(reason.lowercased())"
            account.orders[j].updatedAt = time
            events.append(.canceled(account.orders[j], reason: reason))
        }
    }

    // MARK: Lifecycle

    /// Expires day orders whose session has ended. Call on launch, foreground and timers.
    @discardableResult
    static func expire(account: inout AccountData, now: Date) -> [OrderEvent] {
        var events: [OrderEvent] = []
        for i in account.orders.indices where account.orders[i].status.isWorking {
            guard let expiry = account.orders[i].expiresAt, now >= expiry else { continue }
            account.orders[i].status = .expired
            account.orders[i].statusNote = "Expired at the end of the session"
            account.orders[i].updatedAt = now
            events.append(.expired(account.orders[i]))
            cancelChildren(of: account.orders[i].id, in: &account, reason: "Parent order expired", time: now, events: &events)
        }
        return events
    }

    /// Cancels a pending order and any legs that depend on it.
    @discardableResult
    static func cancel(_ id: UUID, account: inout AccountData, now: Date = Date()) -> Bool {
        guard let index = account.orders.firstIndex(where: { $0.id == id && $0.status.isPending }) else { return false }
        account.orders[index].status = .canceled
        account.orders[index].statusNote = "Canceled by you"
        account.orders[index].updatedAt = now
        var events: [OrderEvent] = []
        cancelChildren(of: id, in: &account, reason: "Parent canceled", time: now, events: &events)
        return true
    }

    /// Moves a working order's prices (dragging an order line on the chart).
    @discardableResult
    static func modify(_ id: UUID, limit: Decimal? = nil, stop: Decimal? = nil, shares: Decimal? = nil,
                       account: inout AccountData, now: Date = Date()) -> Bool {
        guard let i = account.orders.firstIndex(where: { $0.id == id && $0.status.isPending && $0.triggeredAt == nil }) else { return false }
        var order = account.orders[i]
        if let limit { guard order.type.usesLimit, limit > 0 else { return false }; order.limit = limit.rounded(Precision.price) }
        if let stop { guard order.type.usesStop, stop > 0 else { return false }; order.stop = stop.rounded(Precision.price) }
        if let shares { guard shares > 0 else { return false }; order.shares = shares.rounded(Precision.shares, .down) }
        order.updatedAt = now
        account.orders[i] = order
        return true
    }

    /// Position sizing: shares so that hitting `stop` loses `riskAmount`.
    static func shares(risking riskAmount: Decimal, entry: Decimal, stop: Decimal, fractional: Bool = true) -> Decimal {
        let perShare = abs(entry - stop)
        guard perShare > 0, riskAmount > 0 else { return 0 }
        let raw = riskAmount / perShare
        return fractional ? raw.rounded(Precision.shares, .down) : raw.rounded(0, .down)
    }
}
