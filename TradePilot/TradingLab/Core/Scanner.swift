import Foundation

nonisolated struct ScanRow: Identifiable, Hashable, Sendable {
    let symbol: String
    var name: String
    var price: Double
    var changePercent: Double
    var volume: Double?
    var averageVolume: Double?
    var marketCap: Double?
    var open: Double?
    var previousClose: Double?
    var preMarketChangePercent: Double?
    var id: String { symbol }

    /// Today's volume over the 3-month average daily volume (full-day basis).
    var relativeVolume: Double? {
        guard let volume, let averageVolume, averageVolume > 0 else { return nil }
        return volume / averageVolume
    }
    /// Gap from the previous close to today's open, percent points.
    var gapPercent: Double? {
        guard let open, let previousClose, previousClose > 0 else { return preMarketChangePercent }
        return (open / previousClose - 1) * 100
    }
    var dollarVolume: Double? { volume.map { $0 * price } }
}

nonisolated enum ScanPreset: String, CaseIterable, Identifiable, Sendable {
    case gainers = "Top gainers", losers = "Top losers", active = "Most active"
    case gapUp = "Gap up", gapDown = "Gap down", unusualVolume = "Unusual volume", smallCaps = "Small-cap movers"
    var id: String { rawValue }
    var yahooIDs: [String] {
        switch self {
        case .gainers: return ["day_gainers"]
        case .losers: return ["day_losers"]
        case .active: return ["most_actives"]
        case .gapUp, .gapDown, .unusualVolume: return ["day_gainers", "day_losers", "most_actives"]
        case .smallCaps: return ["small_cap_gainers"]
        }
    }
    var detail: String {
        switch self {
        case .gainers: return "Largest percent gains today"
        case .losers: return "Largest percent losses today"
        case .active: return "Highest share volume today"
        case .gapUp: return "Opened well above yesterday's close"
        case .gapDown: return "Opened well below yesterday's close"
        case .unusualVolume: return "Volume far above the 3-month average"
        case .smallCaps: return "Smaller companies moving the most"
        }
    }

    func rank(_ rows: [ScanRow]) -> [ScanRow] {
        switch self {
        case .gainers, .smallCaps: return rows.sorted { $0.changePercent > $1.changePercent }
        case .losers: return rows.sorted { $0.changePercent < $1.changePercent }
        case .active: return rows.sorted { ($0.volume ?? 0) > ($1.volume ?? 0) }
        case .gapUp: return rows.filter { ($0.gapPercent ?? 0) >= 2 }.sorted { ($0.gapPercent ?? 0) > ($1.gapPercent ?? 0) }
        case .gapDown: return rows.filter { ($0.gapPercent ?? 0) <= -2 }.sorted { ($0.gapPercent ?? 0) < ($1.gapPercent ?? 0) }
        case .unusualVolume: return rows.filter { ($0.relativeVolume ?? 0) >= 1.5 }.sorted { ($0.relativeVolume ?? 0) > ($1.relativeVolume ?? 0) }
        }
    }
}

nonisolated struct ScanFilter: Equatable, Sendable {
    var minPrice: Double?
    var maxPrice: Double?
    var minVolume: Double?
    var minRelativeVolume: Double?
    var minAbsChange: Double?
    var minMarketCap: Double?

    var isActive: Bool { [minPrice, maxPrice, minVolume, minRelativeVolume, minAbsChange, minMarketCap].contains { $0 != nil } }

    func matches(_ row: ScanRow) -> Bool {
        if let minPrice, row.price < minPrice { return false }
        if let maxPrice, row.price > maxPrice { return false }
        if let minVolume { guard let v = row.volume, v >= minVolume else { return false } }
        if let minRelativeVolume { guard let r = row.relativeVolume, r >= minRelativeVolume else { return false } }
        if let minAbsChange, abs(row.changePercent) < minAbsChange { return false }
        if let minMarketCap { guard let m = row.marketCap, m >= minMarketCap else { return false } }
        return true
    }

    /// Typical day-trading universe: liquid, not penny stocks.
    static let dayTrading = ScanFilter(minPrice: 2, maxPrice: nil, minVolume: 1_000_000, minRelativeVolume: nil, minAbsChange: nil, minMarketCap: nil)
}

nonisolated enum ScannerParse {
    private static func double(_ value: Any?) -> Double? {
        if let d = value as? Double, d.isFinite { return d }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let raw = (value as? [String: Any])?["raw"] { return double(raw) }
        return nil
    }

    /// Yahoo predefined screener: finance.result[0].quotes[].
    static func yahoo(_ data: Data) -> [ScanRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let finance = root["finance"] as? [String: Any],
              let quotes = ((finance["result"] as? [[String: Any]])?.first)?["quotes"] as? [[String: Any]] else { return [] }
        return quotes.compactMap { q in
            guard let symbol = q["symbol"] as? String, let price = double(q["regularMarketPrice"]), price > 0,
                  (q["quoteType"] as? String ?? "EQUITY") != "MUTUALFUND" else { return nil }
            return ScanRow(symbol: symbol, name: q["shortName"] as? String ?? q["longName"] as? String ?? symbol, price: price,
                           changePercent: double(q["regularMarketChangePercent"]) ?? 0, volume: double(q["regularMarketVolume"]),
                           averageVolume: double(q["averageDailyVolume3Month"]), marketCap: double(q["marketCap"]),
                           open: double(q["regularMarketOpen"]), previousClose: double(q["regularMarketPreviousClose"]),
                           preMarketChangePercent: double(q["preMarketChangePercent"]))
        }
    }

    /// Alpaca movers: { gainers: [{symbol, percent_change, change, price}], losers: [...] }.
    static func alpacaMovers(_ data: Data) -> (gainers: [ScanRow], losers: [ScanRow]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], []) }
        func rows(_ key: String) -> [ScanRow] {
            (root[key] as? [[String: Any]] ?? []).compactMap { r in
                guard let symbol = r["symbol"] as? String, let price = double(r["price"]) else { return nil }
                return ScanRow(symbol: symbol, name: symbol, price: price, changePercent: double(r["percent_change"]) ?? 0)
            }
        }
        return (rows("gainers"), rows("losers"))
    }

    /// Alpaca most actives: { most_actives: [{symbol, volume, trade_count}] }.
    static func alpacaActives(_ data: Data) -> [(symbol: String, volume: Double)] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (root["most_actives"] as? [[String: Any]] ?? []).compactMap { r in
            guard let symbol = r["symbol"] as? String, let volume = double(r["volume"]) else { return nil }
            return (symbol, volume)
        }
    }
}

// MARK: - Alerts

nonisolated struct AlertInputs: Sendable {
    var price: Decimal
    var previousPrice: Decimal?
    var changePercent: Double?
    var vwap: Double?
    var previousVWAPSide: Bool?
    var rsi: Double?
    var relativeVolume: Double?
}

nonisolated enum AlertEvaluator {
    static func isTriggered(_ condition: AlertCondition, _ inputs: AlertInputs) -> Bool {
        switch condition {
        case .priceAbove(let target): return inputs.price >= target
        case .priceBelow(let target): return inputs.price <= target
        case .changeAbove(let pct): return (inputs.changePercent ?? -.infinity) >= pct
        case .changeBelow(let pct): return (inputs.changePercent ?? .infinity) <= pct
        case .crossesAboveVWAP:
            guard let vwap = inputs.vwap, let wasAbove = inputs.previousVWAPSide else { return false }
            return !wasAbove && inputs.price.double > vwap
        case .crossesBelowVWAP:
            guard let vwap = inputs.vwap, let wasAbove = inputs.previousVWAPSide else { return false }
            return wasAbove && inputs.price.double < vwap
        case .rsiAbove(let level): return (inputs.rsi ?? -1) >= level
        case .rsiBelow(let level): return (inputs.rsi ?? 101) <= level
        case .relativeVolumeAbove(let x): return (inputs.relativeVolume ?? 0) >= x
        }
    }

    /// Repeating alerts re-arm after this long.
    static let cooldown: TimeInterval = 15 * 60

    static func isArmed(_ alert: PriceAlert, now: Date) -> Bool {
        guard let fired = alert.triggeredAt else { return true }
        return alert.repeats && now.timeIntervalSince(fired) >= cooldown
    }
}
