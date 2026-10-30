import Foundation
import UserNotifications

/// Practice orders, portfolio history and switching portfolios.
extension LabStore {
    // MARK: Orders

    /// Places a practice order. Returns the recorded order, or nil after showing why it was rejected.
    @discardableResult
    func place(_ request: OrderRequest, note: TradeNote? = nil) -> PracticeOrder? {
        if let locked = lockedReason(for: request) {
            notice = locked
            return nil
        }
        var account = data
        let result = OrderEngine.submit(request, kind: security(request.symbol)?.kind, account: &account,
                                        quote: market.quote(request.symbol), context: context())
        switch result {
        case .failure(let rejection):
            notice = rejection.message
            return nil
        case .success(let order):
            workspace.portfolios[workspace.activeIndex].account = account
            if let note { workspace.features.tradeNotes[order.id.uuidString] = note }
            switch order.status {
            case .filled:
                showToast("\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol) filled at \(Format.money(order.fillPrice ?? 0))")
                recordPortfolio(force: true)
                noteTradeActivity()
            case .queued:
                let when = market.hours.nextOpen(after: Date()).formatted(.dateTime.weekday(.abbreviated).hour().minute())
                showToast("Market closed · \(order.symbol) order queued for the open (\(when) your time)")
            case .open:
                showToast("\(order.summary) working")
            default: break
            }
            refreshLessonTasks()
            return order
        }
    }

    /// Shows a symbol on the Chart tab, closing the stock sheet if it is open.
    func openChart(_ symbol: String) {
        chartSymbol = symbol
        openedStock = nil
        tab = .chart
    }

    /// Everything an order ticket needs to validate and preview a live order.
    func ticketContext(_ symbol: String) -> TicketContext {
        let bars = market.candles(symbol, chartPreferences.timeframe)
        let atr = Indicators.atr(bars.isEmpty ? market.candles(symbol, .m5) : bars).last ?? nil
        return TicketContext(symbol: symbol, kind: security(symbol)?.kind ?? .stock, quote: market.quote(symbol),
                             account: data, market: context(), atr: atr,
                             locked: Set(LabFeature.allCases.filter { !isUnlocked($0) }),
                             coach: { [weak self] request, entry in self?.coachNotes(for: request, entry: entry) ?? [] },
                             coolDownUntil: learning.coolDownUntil)
    }

    /// Ticket for a real order at the connected broker. Coaching still applies; practice locks don't.
    func liveTicketContext(_ symbol: String) -> TicketContext? {
        guard let env = broker.environment else { return nil }
        var context = ticketContext(symbol)
        context.locked = []
        context.coolDownUntil = learning.coolDownUntil
        let held = broker.position(symbol)?.quantity ?? 0
        context.live = LiveTicketInfo(environment: env, buyingPower: broker.account?.buyingPower, equity: broker.account?.equity, heldShares: held)
        context.coach = { [weak self] request, entry in
            guard let self else { return [] }
            var notes = self.coachNotes(for: request, entry: entry).filter { $0.id != "big-risk" && $0.id != "big-position" }
            if let equity = self.broker.account?.equity, equity > 0, let entry {
                let exposure = (request.stopLoss.map { abs(entry - $0) } ?? entry) * request.shares
                let fraction = (exposure / equity).double
                if request.stopLoss != nil && fraction > 0.02 {
                    notes.insert(CoachNote(id: "big-risk", level: .warning, title: "This risks \(Int(fraction * 100))% of your real account",
                                           detail: "Keep real-money risk to 1–2% per trade, at least until your results prove your approach works.", lessonID: "u2-position-size"), at: 0)
                } else if request.stopLoss == nil && fraction > 0.25 {
                    notes.insert(CoachNote(id: "big-position", level: .warning, title: "\(Int(fraction * 100))% of your real account in one trade",
                                           detail: "That's a lot of real money riding on one stock. Consider a smaller size and a stop loss.", lessonID: "u2-position-size"), at: 0)
                }
            }
            return notes
        }
        return context
    }

    /// One-tap market order from the chart's trade bar.
    @discardableResult
    func quickOrder(_ symbol: String, side: OrderSide, shares: Decimal) -> PracticeOrder? {
        place(OrderRequest(symbol: symbol, side: side, shares: shares, type: .market))
    }

    func cancel(_ id: UUID) {
        mutateActive { _ = OrderEngine.cancel(id, account: &$0) }
    }

    func cancelAll(_ symbol: String? = nil) {
        mutateActive { account in
            for order in account.orders where order.status.isPending && order.parentID == nil && (symbol == nil || order.symbol == symbol) {
                OrderEngine.cancel(order.id, account: &account)
            }
        }
    }

    /// Moves a working order (dragging its line on the chart).
    func modify(_ id: UUID, price: Decimal) {
        guard let order = data.orders.first(where: { $0.id == id }) else { return }
        var ok = false
        mutateActive { account in
            ok = order.type.usesStop && order.type != .stopLimit
                ? OrderEngine.modify(id, stop: price, account: &account)
                : order.type.usesLimit ? OrderEngine.modify(id, limit: price, account: &account) : false
        }
        if ok { showToast("\(order.symbol) \(order.role == .entry ? order.type.rawValue.lowercased() : order.role.rawValue.lowercased()) moved to \(Format.money(price))") }
    }

    /// Closes a position at market and cancels its working orders.
    func flatten(_ symbol: String) {
        cancelAll(symbol)
        guard let position = position(symbol) else { return }
        var request = OrderRequest(symbol: symbol, side: position.isLong ? .sell : .buy, shares: position.size, type: .market)
        request.reduceOnly = true
        request.role = .exit
        place(request)
    }

    func flattenAll() {
        for symbol in heldSymbols { flatten(symbol) }
        cancelAll()
    }

    /// Flips a position to the same size on the other side.
    func reverse(_ symbol: String) {
        guard let position = position(symbol) else { return }
        cancelAll(symbol)
        place(OrderRequest(symbol: symbol, side: position.isLong ? .sell : .buy, shares: position.size * 2, type: .market))
    }

    /// Adds a protective stop and/or target to an existing position, as an OCO pair.
    func protect(_ symbol: String, stop: Decimal?, target: Decimal?) {
        guard let position = position(symbol), stop != nil || target != nil else { return }
        let side: OrderSide = position.isLong ? .sell : .buy
        let group = (stop != nil && target != nil) ? UUID() : nil
        var placed: [PracticeOrder] = []
        if let stop {
            var r = OrderRequest(symbol: symbol, side: side, shares: position.size, type: .stop, stop: stop, tif: .gtc)
            r.reduceOnly = true; r.role = .stopLoss
            if let order = place(r) { placed.append(order) }
        }
        if let target {
            var r = OrderRequest(symbol: symbol, side: side, shares: position.size, type: .limit, limit: target, tif: .gtc)
            r.reduceOnly = true; r.role = .takeProfit
            if let order = place(r) { placed.append(order) }
        }
        if let group, placed.count == 2 {
            mutateActive { account in
                for order in placed { if let i = account.orders.firstIndex(where: { $0.id == order.id }) { account.orders[i].ocoID = group } }
            }
        }
    }

    func reflect(_ id: UUID, text: String) {
        mutateActive { account in
            guard let index = account.orders.firstIndex(where: { $0.id == id }) else { return }
            account.orders[index].reflection = text
            account.orders[index].updatedAt = Date()
        }
    }

    /// Every price print lands here before any UI update.
    func handle(symbol: String, quote: Quote) {
        if pendingSymbols.contains(symbol) {
            var updated = workspace
            var events: [OrderEvent] = []
            let context = self.context(now: quote.time)
            for index in updated.portfolios.indices {
                events += OrderEngine.process(symbol: symbol, quote: quote, account: &updated.portfolios[index].account, context: context)
            }
            if !events.isEmpty {
                workspace = updated
                announce(events)
                if events.contains(where: { if case .filled = $0 { return true } else { return false } }) { recordPortfolio(force: true) }
            }
        }
        evaluatePriceAlerts(symbol: symbol, price: quote.price)
        processRecurring(symbol: symbol)
    }

    private func announce(_ events: [OrderEvent]) {
        for event in events {
            switch event {
            case .filled(let o):
                let label = o.role == .entry ? "" : "\(o.role.rawValue): "
                showToast("\(label)\(o.side.rawValue) \(Format.shares(o.shares)) \(o.symbol) filled at \(Format.money(o.fillPrice ?? 0))")
                noteTradeActivity()
            case .canceled(let o, let reason) where reason != "OCO" && !reason.hasPrefix("Parent"):
                showToast("\(o.symbol): \(o.statusNote ?? reason)")
            case .expired(let o): showToast("\(o.symbol) \(o.type.rawValue.lowercased()) order expired")
            case .triggered(let o): if o.type == .stopLimit { showToast("\(o.symbol) stop triggered · limit working") }
            default: break
            }
        }
    }

    /// Expires day orders on a timer (no prices arrive after the close to do it).
    func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.expireOrders()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func expireOrders(now: Date = Date()) {
        var updated = workspace
        var events: [OrderEvent] = []
        for index in updated.portfolios.indices { events += OrderEngine.expire(account: &updated.portfolios[index].account, now: now) }
        guard !events.isEmpty else { return }
        workspace = updated
        let count = events.filter { if case .expired = $0 { return true } else { return false } }.count
        if count > 0 { showToast("\(count) day \(count == 1 ? "order" : "orders") expired at the close") }
    }

    func reset() {
        let index = workspace.activeIndex
        var updated = workspace
        let old = updated.portfolios[index].account
        var fresh = AccountData(name: old.name, goal: old.goal, initialBalance: old.initialBalance, onboardingComplete: true)
        fresh.settings = old.settings
        fresh.resetAt = Date()
        fresh.updatedAt = fresh.resetAt
        updated.portfolios[index].account = fresh
        updated.portfolios[index].history = []
        updated.pruneOrphans()
        workspace = updated
        notice = "Practice account reset."
    }

    // MARK: Portfolio history

    func recordPortfolio(force: Bool = false, now: Date = Date()) {
        guard let value = portfolioValue?.double, value.isFinite else { return }
        let index = workspace.activeIndex
        var history = workspace.portfolios[index].history
        if let last = history.last {
            if !force && now.timeIntervalSince(last.date) < AppConfig.portfolioRecordInterval { return }
            if abs(last.value - value) < 0.01 && now.timeIntervalSince(last.date) < 3600 { return }
        }
        history.append(PortfolioSample(date: now, value: value))
        let calendar = Calendar.current
        let fiveYearCutoff = calendar.date(byAdding: .year, value: -5, to: now) ?? .distantPast
        let recentCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        let retained = history.filter { $0.date >= fiveYearCutoff }
        var onePerDay: [Date: PortfolioSample] = [:]
        for sample in retained where sample.date < recentCutoff { onePerDay[calendar.startOfDay(for: sample.date)] = sample }
        let recent = Array(retained.filter { $0.date >= recentCutoff }.suffix(2_000))
        history = onePerDay.values.sorted { $0.date < $1.date } + recent
        quietly { workspace.portfolios[index].history = history }
        publishWidget()
    }

    // MARK: Portfolios

    func switchPortfolio(_ id: String) {
        guard id != workspace.activePortfolioID, workspace.portfolios.contains(where: { $0.id == id }) else { return }
        quietly { workspace.activePortfolioID = id }
        recordPortfolio(force: true)
        publishWidget()
    }

    func createPortfolio(title: String, balance: Decimal) {
        guard balance > 0, !title.isEmpty else { return }
        var account = AccountData(name: data.name, goal: data.goal, initialBalance: balance.rounded(Precision.cash), onboardingComplete: true)
        account.settings = data.settings
        let portfolio = Portfolio(id: UUID().uuidString, title: title, account: account)
        workspace.portfolios.append(portfolio)
        switchPortfolio(portfolio.id)
    }

    func deletePortfolio(_ id: String) {
        guard id != Portfolio.primaryID, id != workspace.activePortfolioID else { return }
        var updated = workspace
        updated.portfolios.removeAll { $0.id == id }
        updated.tombstones["portfolio:\(id)"] = Date()
        updated.pruneOrphans()
        workspace = updated
    }
}
