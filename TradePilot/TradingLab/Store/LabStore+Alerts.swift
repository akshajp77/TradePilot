import Foundation
import UserNotifications

/// Saved research, tracked events, price and indicator alerts, recurring buys.
extension LabStore {
    // MARK: Research, events, alerts, schedules

    func isArticleSaved(_ url: URL) -> Bool { workspace.features.research.contains { $0.url == url } }

    func toggleArticle(_ article: NewsArticle) {
        if let saved = workspace.features.research.first(where: { $0.url == article.url }) { removeResearch(saved.id) }
        else {
            saveResearch(SavedResearch(title: article.cleanTitle, source: article.source, url: article.url, date: article.date,
                                       symbol: article.symbols.first ?? ""))
        }
    }

    func saveResearch(_ record: SavedResearch) {
        var record = record
        record.savedAt = Date()
        if let i = workspace.features.research.firstIndex(where: { $0.id == record.id }) { workspace.features.research[i] = record }
        else { workspace.features.research.insert(record, at: 0) }
    }

    func removeResearch(_ id: String) {
        var updated = workspace
        updated.features.research.removeAll { $0.id == id }
        updated.tombstones["research:\(id)"] = Date()
        workspace = updated
    }

    func saveEvent(_ event: TrackedEvent) {
        if let i = workspace.features.events.firstIndex(where: { $0.id == event.id }) { workspace.features.events[i] = event }
        else { workspace.features.events.append(event) }
    }

    func removeEvent(_ id: String) {
        var updated = workspace
        updated.features.events.removeAll { $0.id == id }
        updated.tombstones["event:\(id)"] = Date()
        workspace = updated
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func addAlert(symbol: String, condition: AlertCondition, repeats: Bool = false, note: String = "") {
        workspace.features.alerts.append(PriceAlert(symbol: symbol, condition: condition, note: note, repeats: repeats))
        recordAction("alert")
        if condition.needsIntradayBars { Task { await market.loadBars(symbol, timeframe: .m5) } }
        if let price = market.decimalPrice(symbol) { evaluatePriceAlerts(symbol: symbol, price: price) }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func removeAlert(_ id: String) {
        var updated = workspace
        updated.features.alerts.removeAll { $0.id == id }
        updated.tombstones["alert:\(id)"] = Date()
        workspace = updated
    }

    func rearmAlert(_ id: String) {
        guard let i = workspace.features.alerts.firstIndex(where: { $0.id == id }) else { return }
        workspace.features.alerts[i].triggeredAt = nil
    }

    func addSchedule(symbol: String, dollars: Decimal, intervalDays: Int, firstDate: Date) {
        workspace.features.recurring.append(ScheduledInvestment(portfolio: workspace.activePortfolioID, symbol: symbol,
                                                                dollars: dollars.rounded(Precision.cash), intervalDays: intervalDays,
                                                                nextDate: firstDate))
        processRecurring()
    }

    func setScheduleEnabled(_ id: String, _ enabled: Bool) {
        guard let i = workspace.features.recurring.firstIndex(where: { $0.id == id }) else { return }
        workspace.features.recurring[i].enabled = enabled
    }

    func deleteSchedule(_ id: String) {
        var updated = workspace
        updated.features.recurring.removeAll { $0.id == id }
        updated.tombstones["recurring:\(id)"] = Date()
        workspace = updated
    }

    func loadAlertBars() {
        let symbols = Set(workspace.features.alerts.filter { $0.condition.needsIntradayBars }.map(\.symbol))
        for symbol in symbols { Task { await market.loadBars(symbol, timeframe: .m5) } }
    }

    func evaluatePriceAlerts(symbol: String, price: Decimal) {
        let inputs = AlertInputs(price: price, changePercent: market.change(symbol))
        fireAlerts(symbol: symbol, inputs: inputs) { !$0.needsIntradayBars }
    }

    /// VWAP, RSI and relative-volume alerts, evaluated when 5-minute candles update.
    func evaluateIndicatorAlerts(symbol: String) {
        guard workspace.features.alerts.contains(where: { $0.symbol == symbol && $0.condition.needsIntradayBars }) else { return }
        let bars = market.candles(symbol, .m5)
        guard let price = market.decimalPrice(symbol) ?? bars.last.map({ .price($0.close) }) else { return }
        let vwap = Indicators.vwap(bars, hours: market.hours).last ?? nil
        let rsi = Indicators.rsi(bars.map(\.close)).last ?? nil
        let side = vwap.map { price.double > $0 }
        let inputs = AlertInputs(price: price, changePercent: market.change(symbol), vwap: vwap, previousVWAPSide: vwapSide[symbol],
                                 rsi: rsi, relativeVolume: Indicators.relativeVolume(bars, hours: market.hours))
        fireAlerts(symbol: symbol, inputs: inputs) { $0.needsIntradayBars }
        if let side { vwapSide[symbol] = side }
    }

    private func fireAlerts(symbol: String, inputs: AlertInputs, where include: (AlertCondition) -> Bool) {
        let now = Date()
        var alerts = workspace.features.alerts
        var fired: [PriceAlert] = []
        for i in alerts.indices where alerts[i].symbol == symbol && include(alerts[i].condition) && AlertEvaluator.isArmed(alerts[i], now: now) {
            guard AlertEvaluator.isTriggered(alerts[i].condition, inputs) else { continue }
            alerts[i].triggeredAt = now
            fired.append(alerts[i])
        }
        guard !fired.isEmpty else { return }
        workspace.features.alerts = alerts
        for alert in fired {
            let content = UNMutableNotificationContent()
            content.title = "\(symbol): \(alert.condition.title)"
            content.body = (alert.note.isEmpty ? "" : alert.note + " · ") + "Last price \(Format.money(inputs.price))."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id + "-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil))
        }
        showToast("\(symbol) alert · \(fired[0].condition.title)")
    }

    /// Runs due schedules for every portfolio. Never touches `notice`. Missed periods are skipped.
    func processRecurring(symbol: String? = nil, now: Date = Date()) {
        var updated = workspace
        var changed = false
        var messages: [String] = []
        let context = self.context(now: now)
        for i in updated.features.recurring.indices {
            let schedule = updated.features.recurring[i]
            guard schedule.enabled, schedule.nextDate <= now, symbol == nil || schedule.symbol == symbol,
                  let p = updated.portfolios.firstIndex(where: { $0.id == schedule.portfolio }) else { continue }
            var message: String
            if let quote = market.quote(schedule.symbol), quote.price > 0 {
                var request = OrderRequest(symbol: schedule.symbol, side: .buy, shares: (schedule.dollars / quote.price).rounded(Precision.shares, .down), type: .market)
                request.thesis = "Scheduled virtual investment"
                request.invalidation = "Review if my investment plan changes"
                request.horizon = "Recurring"
                switch OrderEngine.submit(request, kind: security(schedule.symbol)?.kind, account: &updated.portfolios[p].account, quote: quote, context: context) {
                case .success(let order):
                    let day = now.formatted(date: .abbreviated, time: .omitted)
                    message = order.status == .filled
                        ? "Bought \(Format.shares(order.shares)) shares on \(day)"
                        : "Queued \(Format.shares(order.shares)) shares on \(day) for the next open"
                    updated.features.tradeNotes[order.id.uuidString] = TradeNote(strategy: "Long-term")
                    var next = schedule.nextDate
                    repeat { next = Calendar.current.date(byAdding: .day, value: schedule.intervalDays, to: next) ?? .distantFuture } while next <= now
                    updated.features.recurring[i].nextDate = next
                    messages.append("\(schedule.symbol): \(message.lowercased())")
                case .failure(let rejection):
                    switch rejection {
                    case .insufficientBuyingPower: message = "Due · not enough buying power"
                    case .noPrice: message = "Due · waiting for a recent price"
                    default: message = "Due · \(rejection.message)"
                    }
                }
            } else {
                message = "Due · waiting for a recent price"
            }
            if updated.features.recurring[i].lastMessage != message || updated.features.recurring[i].nextDate != schedule.nextDate {
                updated.features.recurring[i].lastMessage = message
                changed = true
            }
        }
        guard changed else { return }
        workspace = updated
        if let first = messages.first { showToast("Scheduled purchase · \(first)") }
    }

    func refreshUserFeatures() {
        expireOrders()
        processRecurring()
        for alert in workspace.features.alerts where AlertEvaluator.isArmed(alert, now: Date()) {
            if let price = market.decimalPrice(alert.symbol) { evaluatePriceAlerts(symbol: alert.symbol, price: price) }
        }
        publishWidget()
    }
}
