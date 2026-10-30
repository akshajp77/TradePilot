import Foundation

// Pure decoders for every feed. They run off the main actor and return Sendable values.

nonisolated struct PricePoint: Identifiable, Hashable, Sendable {
    let date: Date
    let price: Double
    var id: Date { date }
}

nonisolated struct ChartPayload: Sendable {
    var symbol: String
    var price: Double?
    var time: Date?
    var previousClose: Double?
    var open: Double?
    var dayHigh: Double?
    var dayLow: Double?
    var volume: Double?
    var fiftyTwoWeekHigh: Double?
    var fiftyTwoWeekLow: Double?
    var exchange: String?
    var name: String?
    var instrumentType: String?
    var currency: String?
    var points: [PricePoint] = []
    /// Full OHLCV bars (null rows dropped).
    var bars: [Bar] = []
}

nonisolated struct SearchResult: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let kind: SecurityKind
    var id: String { symbol }
}

nonisolated struct NewsArticle: Identifiable, Hashable, Sendable {
    let title: String
    let source: String
    let date: Date
    let url: URL
    var imageURL: URL?
    var thumbnailURL: URL?
    var symbols: [String] = []
    /// Publisher-provided abstract when the feed has one. Full article text is never copied into the app.
    var summary: String?
    var id: String { url.absoluteString }
    var cleanTitle: String {
        let suffix = " - \(source)"
        if title.lowercased().hasSuffix(suffix.lowercased()) {
            return String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
    func ageLabel(now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

nonisolated struct Fundamentals: Codable, Sendable, Equatable {
    var marketCap: Double?
    var peRatio: Double?
    var eps: Double?
    var beta: Double?
    var dividendYield: Double?
    var fiftyTwoWeekHigh: Double?
    var fiftyTwoWeekLow: Double?
}

nonisolated enum StreamEvent: Equatable, Sendable {
    case authenticated
    case subscribed
    case error(String)
    case trade(symbol: String, price: Double, size: Double, time: Date)
    case quote(symbol: String, bid: Double, bidSize: Double, ask: Double, askSize: Double, time: Date)
}

nonisolated struct EarningsDate: Codable, Hashable, Sendable {
    var date: Date
    /// "bmo" before market open, "amc" after market close, or nil.
    var hour: String?
    var epsEstimate: Double?
    var epsActual: Double?
    var timing: String {
        switch hour { case "bmo": return "before the open"; case "amc": return "after the close"; default: return "" }
    }
}

nonisolated struct AIImpact: Codable, Sendable, Equatable {
    enum Direction: String, Codable, Sendable { case up, down, mixed }
    let summary: String
    let direction: Direction
    let impact: String
    let watch: String
    let questions: [String]
}

nonisolated enum Parse {
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func double(_ value: Any?) -> Double? {
        if let d = value as? Double, d.isFinite { return d }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        return nil
    }
    private static func https(_ raw: Any?) -> URL? {
        guard let raw = raw as? String, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    static func iso8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        // Alpaca stream timestamps carry nanoseconds; trim to milliseconds.
        if let dot = raw.firstIndex(of: "."), let zone = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = raw[raw.index(after: dot)..<zone].prefix(3)
            if let date = formatter.date(from: String(raw[..<dot]) + "." + fraction + String(raw[zone...])) { return date }
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    static func yahooChart(_ data: Data, symbol: String) -> ChartPayload? {
        guard let root = object(data), let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any] else { return nil }
        let timestamps = (result["timestamp"] as? [Any])?.compactMap(double) ?? []
        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first
        let closes = quote?["close"] as? [Any] ?? []
        let opens = quote?["open"] as? [Any] ?? [], highs = quote?["high"] as? [Any] ?? []
        let lows = quote?["low"] as? [Any] ?? [], volumes = quote?["volume"] as? [Any] ?? []
        let points: [PricePoint] = closes.enumerated().compactMap { index, raw in
            guard index < timestamps.count, let close = double(raw), close > 0 else { return nil }
            return PricePoint(date: Date(timeIntervalSince1970: timestamps[index]), price: close)
        }
        var bars: [Bar] = []
        bars.reserveCapacity(closes.count)
        for index in closes.indices where index < timestamps.count {
            guard let close = double(closes[index]), close > 0 else { continue }
            let open = index < opens.count ? double(opens[index]) ?? close : close
            let high = index < highs.count ? double(highs[index]) ?? max(open, close) : max(open, close)
            let low = index < lows.count ? double(lows[index]) ?? min(open, close) : min(open, close)
            let volume = index < volumes.count ? double(volumes[index]) ?? 0 : 0
            bars.append(Bar(time: Date(timeIntervalSince1970: timestamps[index]), open: open, high: max(high, open, close),
                            low: min(low, open, close), close: close, volume: volume))
        }
        var payload = ChartPayload(symbol: symbol)
        payload.price = double(meta["regularMarketPrice"]) ?? points.last?.price
        payload.time = double(meta["regularMarketTime"]).map(Date.init(timeIntervalSince1970:)) ?? points.last?.date
        payload.previousClose = points.dropLast().last?.price ?? double(meta["previousClose"]) ?? double(meta["chartPreviousClose"])
        payload.open = (quote?["open"] as? [Any])?.compactMap(double).last
        payload.dayHigh = double(meta["regularMarketDayHigh"])
        payload.dayLow = double(meta["regularMarketDayLow"])
        payload.volume = double(meta["regularMarketVolume"])
        payload.fiftyTwoWeekHigh = double(meta["fiftyTwoWeekHigh"])
        payload.fiftyTwoWeekLow = double(meta["fiftyTwoWeekLow"])
        payload.exchange = meta["fullExchangeName"] as? String
        payload.name = meta["longName"] as? String ?? meta["shortName"] as? String
        payload.instrumentType = meta["instrumentType"] as? String
        payload.currency = meta["currency"] as? String
        payload.points = points
        payload.bars = bars
        return payload
    }

    static func securityKind(yahooType: String?) -> SecurityKind? {
        switch yahooType {
        case "EQUITY": return .stock
        case "ETF": return .etf
        case "INDEX": return .index
        default: return nil
        }
    }

    static func yahooSearchQuotes(_ data: Data) -> [SearchResult] {
        guard let quotes = object(data)?["quotes"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return quotes.compactMap { quote in
            guard let symbol = quote["symbol"] as? String, seen.insert(symbol).inserted,
                  let kind = securityKind(yahooType: quote["quoteType"] as? String) else { return nil }
            return SearchResult(symbol: symbol, name: quote["longname"] as? String ?? quote["shortname"] as? String ?? symbol, kind: kind)
        }
    }

    static func yahooNews(_ data: Data, symbol: String) -> [NewsArticle] {
        guard let rows = object(data)?["news"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let title = row["title"] as? String, let url = https(row["link"]) else { return nil }
            let related = row["relatedTickers"] as? [String] ?? []
            if !related.isEmpty && !related.contains(where: { $0.replacingOccurrences(of: "-", with: ".") == symbol }) { return nil }
            let resolutions = (row["thumbnail"] as? [String: Any])?["resolutions"] as? [[String: Any]] ?? []
            let images = resolutions.sorted {
                (($0["width"] as? Int ?? 0) * ($0["height"] as? Int ?? 0)) > (($1["width"] as? Int ?? 0) * ($1["height"] as? Int ?? 0))
            }.compactMap { https($0["url"]) }
            return NewsArticle(title: title, source: row["publisher"] as? String ?? "Publisher",
                               date: double(row["providerPublishTime"]).map(Date.init(timeIntervalSince1970:)) ?? Date(),
                               url: url, imageURL: images.first, thumbnailURL: images.last,
                               symbols: related.isEmpty ? [symbol] : related)
        }
    }

    static func alpacaSnapshot(_ data: Data) -> (price: Double, time: Date, previousClose: Double?)? {
        guard let root = object(data) else { return nil }
        let latest = root["latestTrade"] as? [String: Any]
        let daily = root["dailyBar"] as? [String: Any]
        guard let price = double(latest?["p"]) ?? double(daily?["c"]), price > 0 else { return nil }
        let time = iso8601(latest?["t"] as? String) ?? iso8601(daily?["t"] as? String) ?? .distantPast
        return (price, time, double((root["prevDailyBar"] as? [String: Any])?["c"]))
    }

    static func alpacaBars(_ data: Data) -> [PricePoint] {
        guard let bars = object(data)?["bars"] as? [[String: Any]] else { return [] }
        return bars.compactMap { bar in
            guard let close = double(bar["c"]), close > 0, let date = iso8601(bar["t"] as? String) else { return nil }
            return PricePoint(date: date, price: close)
        }
    }

    static func alpacaStream(_ data: Data) -> [StreamEvent] {
        guard let events = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            switch event["T"] as? String {
            case "success" where event["msg"] as? String == "authenticated": return .authenticated
            case "subscription": return .subscribed
            case "error": return .error(event["msg"] as? String ?? "authentication or subscription failed")
            case "t":
                guard let symbol = event["S"] as? String, let price = double(event["p"]), price > 0,
                      let time = iso8601(event["t"] as? String) else { return nil }
                return .trade(symbol: symbol, price: price, size: double(event["s"]) ?? 0, time: time)
            case "q":
                guard let symbol = event["S"] as? String, let bid = double(event["bp"]), let ask = double(event["ap"]),
                      bid > 0, ask >= bid, let time = iso8601(event["t"] as? String) else { return nil }
                return .quote(symbol: symbol, bid: bid, bidSize: double(event["bs"]) ?? 0, ask: ask, askSize: double(event["as"]) ?? 0, time: time)
            default: return nil
            }
        }
    }

    static func alpacaNews(_ data: Data) -> [NewsArticle] {
        guard let rows = object(data)?["news"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let title = row["headline"] as? String, let url = https(row["url"]) else { return nil }
            let images = (row["images"] as? [[String: Any]] ?? []).compactMap { https($0["url"]) }
            let summary = (row["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NewsArticle(title: title, source: row["source"] as? String ?? "Alpaca News",
                               date: iso8601(row["created_at"] as? String) ?? Date(), url: url,
                               imageURL: images.first, thumbnailURL: images.last,
                               symbols: row["symbols"] as? [String] ?? [], summary: summary?.isEmpty == false ? summary : nil)
        }
    }

    /// Server earnings proxy: [{ date: "2026-10-30", hour: "amc", epsEstimate, epsActual }].
    static func earnings(_ data: Data) -> [EarningsDate] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return rows.compactMap { row in
            guard let raw = row["date"] as? String, let date = formatter.date(from: raw) else { return nil }
            let hour = (row["hour"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return EarningsDate(date: date, hour: hour, epsEstimate: double(row["epsEstimate"]), epsActual: double(row["epsActual"]))
        }.sorted { $0.date < $1.date }
    }

    static func fundamentals(_ data: Data) -> Fundamentals? {
        try? JSONDecoder().decode(Fundamentals.self, from: data)
    }

    /// Gemini returns JSON as text; accept it only if it has the exact shape we render.
    static func aiImpact(_ text: String) -> AIImpact? {
        let clean = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = try? JSONDecoder().decode(AIImpact.self, from: Data(clean.utf8)) else { return nil }
        func trim(_ s: String, _ n: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n)) }
        let result = AIImpact(summary: trim(decoded.summary, 600), direction: decoded.direction, impact: trim(decoded.impact, 600),
                              watch: trim(decoded.watch, 300),
                              questions: decoded.questions.map { trim($0, 200) }.filter { !$0.isEmpty }.prefix(2).map { $0 })
        guard !result.summary.isEmpty, !result.impact.isEmpty else { return nil }
        return result
    }
}

/// Company profile plus annual results, from the server's /market/financials endpoint.
nonisolated struct CompanyFinancials: Decodable, Sendable, Equatable {
    struct Year: Decodable, Sendable, Equatable, Identifiable {
        let year: Int
        let revenue: Double?
        let netIncome: Double?
        var id: Int { year }
        /// Profit as a share of sales.
        var margin: Double? {
            guard let revenue, let netIncome, revenue > 0 else { return nil }
            return netIncome / revenue
        }
    }
    let name: String?
    let industry: String?
    let country: String?
    let ipo: String?
    let website: String?
    let years: [Year]

    /// Revenue growth from the first to the last year shown, per year on average.
    var revenueGrowth: Double? {
        let points = years.compactMap { y in y.revenue.map { (y.year, $0) } }
        guard let first = points.first, let last = points.last, last.0 > first.0, first.1 > 0, last.1 > 0 else { return nil }
        return pow(last.1 / first.1, 1 / Double(last.0 - first.0)) - 1
    }
}
