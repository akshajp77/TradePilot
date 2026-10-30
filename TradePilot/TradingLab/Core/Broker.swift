import Foundation

// Real-money trading through Alpaca's Trading API. This file holds the pure parts (request
// building, validation, response parsing) so they can be tested without a network.

nonisolated enum BrokerEnvironment: String, Codable, CaseIterable, Sendable {
    case paper, live
    var baseURL: URL { URL(string: self == .live ? "https://api.alpaca.markets" : "https://paper-api.alpaca.markets")! }
    var title: String { self == .live ? "Real money" : "Alpaca paper (fake money)" }
}

nonisolated enum BrokerAuth: Sendable, Equatable {
    case keys(id: String, secret: String)
    case oauth(token: String)

    var headers: [String: String] {
        switch self {
        case .keys(let id, let secret): return ["APCA-API-KEY-ID": id, "APCA-API-SECRET-KEY": secret]
        case .oauth(let token): return ["Authorization": "Bearer \(token)"]
        }
    }
}

nonisolated struct LiveAccount: Sendable, Equatable {
    var accountNumber: String
    var status: String
    var cash: Decimal
    var equity: Decimal
    var lastEquity: Decimal
    var buyingPower: Decimal
    var dayTradeCount: Int
    var patternDayTrader: Bool
    var tradingBlocked: Bool
    var shortingEnabled: Bool
    var dayChange: Decimal { equity - lastEquity }
}

nonisolated struct LivePosition: Identifiable, Sendable, Equatable {
    var id: String { symbol }
    var symbol: String
    /// Signed: negative for short.
    var quantity: Decimal
    var averageEntry: Decimal
    var marketValue: Decimal
    var unrealized: Decimal
    var currentPrice: Decimal
    var changeToday: Double
}

nonisolated struct LiveOrder: Identifiable, Sendable, Equatable {
    var id: String
    var symbol: String
    var side: OrderSide
    var type: String
    var quantity: Decimal?
    var notional: Decimal?
    var filledQuantity: Decimal
    var filledAverage: Decimal?
    var limit: Decimal?
    var stop: Decimal?
    var status: String
    var timeInForce: String
    var orderClass: String
    var submittedAt: Date?
    var filledAt: Date?
    var legs: [LiveOrder] = []

    static let openStatuses: Set<String> = ["new", "partially_filled", "accepted", "pending_new", "accepted_for_bidding", "held", "pending_replace", "pending_cancel", "calculated"]
    var isOpen: Bool { Self.openStatuses.contains(status) }

    /// Plain-language status for beginners.
    var statusText: String {
        switch status {
        case "new", "accepted", "pending_new", "accepted_for_bidding": return "Waiting to fill"
        case "partially_filled": return "Partly filled"
        case "filled": return "Filled"
        case "canceled": return "Canceled"
        case "expired", "done_for_day": return "Expired"
        case "rejected": return "Rejected by the broker"
        case "held": return "Waiting (activates after the first order fills)"
        case "pending_cancel": return "Canceling…"
        case "pending_replace": return "Updating…"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var summary: String {
        let qty = quantity.map(Format.shares) ?? notional.map { Format.money($0) } ?? ""
        let price = limit.map { " @ \(Format.money($0))" } ?? stop.map { " stop \(Format.money($0))" } ?? ""
        return "\(side.rawValue) \(qty) \(symbol) \(type.replacingOccurrences(of: "_", with: " "))\(price)"
    }
}

nonisolated enum AlpacaTrading {
    // MARK: Requests

    /// Alpaca's own rules, checked before sending so beginners get a clear message instead of a 422.
    static func validate(_ r: OrderRequest) -> String? {
        if r.shares <= 0 { return "Enter how many shares." }
        let fractional = r.shares != r.shares.rounded(0, .down)
        if fractional && !(r.type == .market && r.tif == .day && r.takeProfit == nil && r.stopLoss == nil) {
            return "Partial shares only work with a market order that lasts for the day, without a stop loss or target attached. Use a whole number of shares."
        }
        if r.extendedHours && !(r.type == .limit) { return "Before and after regular hours, only limit orders are allowed." }
        if r.type.usesLimit && r.limit == nil { return "Set a limit price." }
        if r.type.usesStop && r.stop == nil { return "Set a stop price." }
        if r.type == .trailingStop && r.trailAmount == nil && r.trailPercent == nil { return "Set how far the trailing stop should follow." }
        if (r.takeProfit != nil || r.stopLoss != nil) && r.type == .trailingStop { return "A trailing stop can't have a stop loss and target attached." }
        if let stop = r.stopLoss, let target = r.takeProfit {
            if r.side == .buy && !(stop < target) { return "For a buy, the stop loss must be below the profit target." }
            if r.side == .sell && !(stop > target) { return "For a short, the stop loss must be above the profit target." }
        }
        if r.extendedHours && (r.takeProfit != nil || r.stopLoss != nil) { return "Stop loss and target orders can't be attached outside regular hours." }
        return nil
    }

    static func orderBody(_ r: OrderRequest, clientOrderID: String = UUID().uuidString) -> [String: Any] {
        func s(_ d: Decimal) -> String { NSDecimalNumber(decimal: d).stringValue }
        var body: [String: Any] = [
            "symbol": r.symbol.uppercased(),
            "qty": s(r.shares),
            "side": r.side == .buy ? "buy" : "sell",
            "time_in_force": r.tif == .gtc ? "gtc" : "day",
            "client_order_id": clientOrderID,
        ]
        switch r.type {
        case .market: body["type"] = "market"
        case .limit: body["type"] = "limit"
        case .stop: body["type"] = "stop"
        case .stopLimit: body["type"] = "stop_limit"
        case .trailingStop: body["type"] = "trailing_stop"
        }
        if let limit = r.limit, r.type.usesLimit { body["limit_price"] = s(limit.tickRounded) }
        if let stop = r.stop, r.type.usesStop { body["stop_price"] = s(stop.tickRounded) }
        if r.type == .trailingStop {
            if let pct = r.trailPercent { body["trail_percent"] = s((pct * 100).rounded(2)) }
            else if let amount = r.trailAmount { body["trail_price"] = s(amount.tickRounded) }
        }
        if r.extendedHours && r.type == .limit { body["extended_hours"] = true }
        switch (r.takeProfit, r.stopLoss) {
        case let (tp?, sl?):
            body["order_class"] = "bracket"
            body["take_profit"] = ["limit_price": s(tp.tickRounded)]
            body["stop_loss"] = ["stop_price": s(sl.tickRounded)]
        case let (nil, sl?):
            body["order_class"] = "oto"
            body["stop_loss"] = ["stop_price": s(sl.tickRounded)]
        case let (tp?, nil):
            body["order_class"] = "oto"
            body["take_profit"] = ["limit_price": s(tp.tickRounded)]
        default: break
        }
        return body
    }

    // MARK: Responses

    private static func dec(_ value: Any?) -> Decimal? {
        if let s = value as? String { return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) }
        if let n = value as? NSNumber { return n.decimalValue }
        return nil
    }
    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Alpaca sends nanoseconds; trim to milliseconds.
        if let dot = s.firstIndex(of: "."), let end = s.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), end > dot {
            let fraction = s[s.index(after: dot)..<end].prefix(3)
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: String(s[..<dot]) + "." + fraction + String(s[end...]))
        }
        return nil
    }

    static func account(_ data: Data) -> LiveAccount? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let equity = dec(o["equity"]) else { return nil }
        return LiveAccount(accountNumber: o["account_number"] as? String ?? "", status: o["status"] as? String ?? "",
                           cash: dec(o["cash"]) ?? 0, equity: equity, lastEquity: dec(o["last_equity"]) ?? equity,
                           buyingPower: dec(o["buying_power"]) ?? 0, dayTradeCount: (o["daytrade_count"] as? NSNumber)?.intValue ?? 0,
                           patternDayTrader: o["pattern_day_trader"] as? Bool ?? false,
                           tradingBlocked: (o["trading_blocked"] as? Bool ?? false) || (o["account_blocked"] as? Bool ?? false),
                           shortingEnabled: o["shorting_enabled"] as? Bool ?? false)
    }

    static func positions(_ data: Data) -> [LivePosition] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { o in
            guard let symbol = o["symbol"] as? String, let qty = dec(o["qty"]) else { return nil }
            let short = (o["side"] as? String) == "short"
            return LivePosition(symbol: symbol, quantity: short && qty > 0 ? -qty : qty, averageEntry: dec(o["avg_entry_price"]) ?? 0,
                                marketValue: dec(o["market_value"]) ?? 0, unrealized: dec(o["unrealized_pl"]) ?? 0,
                                currentPrice: dec(o["current_price"]) ?? 0, changeToday: (dec(o["change_today"]) ?? 0).double)
        }
    }

    static func order(_ o: [String: Any]) -> LiveOrder? {
        guard let id = o["id"] as? String, let symbol = o["symbol"] as? String else { return nil }
        return LiveOrder(id: id, symbol: symbol, side: (o["side"] as? String) == "sell" ? .sell : .buy,
                         type: o["type"] as? String ?? o["order_type"] as? String ?? "", quantity: dec(o["qty"]), notional: dec(o["notional"]),
                         filledQuantity: dec(o["filled_qty"]) ?? 0, filledAverage: dec(o["filled_avg_price"]),
                         limit: dec(o["limit_price"]), stop: dec(o["stop_price"]), status: o["status"] as? String ?? "",
                         timeInForce: o["time_in_force"] as? String ?? "", orderClass: o["order_class"] as? String ?? "simple",
                         submittedAt: date(o["submitted_at"]), filledAt: date(o["filled_at"]),
                         legs: (o["legs"] as? [[String: Any]] ?? []).compactMap(order))
    }

    static func orders(_ data: Data) -> [LiveOrder] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap(order)
    }

    static func singleOrder(_ data: Data) -> LiveOrder? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap(order)
    }

    /// Alpaca's error body is {"code": ..., "message": "..."}; translate the common ones.
    static func errorMessage(status: Int, data: Data) -> String {
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
        let lower = message.lowercased()
        if status == 401 { return "Alpaca didn't accept your login. Reconnect your account in Settings → Real-money trading." }
        if status == 403 && lower.contains("buying power") { return "Not enough buying power for this order." }
        if lower.contains("insufficient qty") || lower.contains("insufficient quantity") { return "You don't have enough shares available to sell. Some may be tied up in other open orders." }
        if lower.contains("pattern day trad") { return "Alpaca blocked this order under the day-trading rules for your account." }
        if lower.contains("not shortable") || lower.contains("cannot be sold short") { return "This stock can't be sold short right now." }
        if lower.contains("market hours") || lower.contains("market is closed") { return "That order type isn't allowed while the market is closed." }
        if status == 403 { return message.isEmpty ? "Alpaca refused the order (not enough buying power or shares)." : "Alpaca refused the order: \(message)" }
        if status == 422 { return message.isEmpty ? "Alpaca couldn't read that order. Check the prices and quantity." : "Alpaca couldn't accept that order: \(message)" }
        if status == 429 { return "Too many requests to Alpaca. Wait a few seconds and try again." }
        return message.isEmpty ? "Alpaca returned an error (\(status))." : message
    }
}
