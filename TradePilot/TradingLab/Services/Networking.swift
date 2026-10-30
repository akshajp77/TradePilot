import Foundation

/// Runs CPU work on a background thread regardless of the caller's isolation
/// (Swift 6.2 runs nonisolated async functions on the caller's actor by default).
nonisolated func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: work).value
}

/// Runs `transform` over `items` with at most `limit` in flight, preserving order.
nonisolated func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int,
                                                         _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
    guard !items.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(max(1, limit), items.count) {
            let index = next, item = items[next]
            group.addTask { (index, await transform(item)) }
            next += 1
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let i = next, item = items[next]
                group.addTask { (i, await transform(item)) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}

/// Market and news feeds. Network waits suspend; every JSON/XML parse runs off the main actor.
nonisolated enum Feeds {
    private static let yahooHosts = ["query1.finance.yahoo.com", "query2.finance.yahoo.com"]

    static func escape(_ symbol: String) -> String {
        symbol.replacingOccurrences(of: ".", with: "-").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
    }

    static func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("TradingLab/2.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Yahoo (undocumented JSON endpoints; HTML scraping is gone)

    static func yahooChart(_ symbol: String, range: String, interval: String) async -> ChartPayload? {
        for host in yahooHosts {
            guard let url = URL(string: "https://\(host)/v8/finance/chart/\(escape(symbol))?range=\(range)&interval=\(interval)"),
                  let data = await get(url) else { continue }
            if let payload = await offMain({ Parse.yahooChart(data, symbol: symbol) }) { return payload }
        }
        return nil
    }

    /// OHLCV bars for a chart timeframe. Intraday requests include pre- and post-market bars.
    static func yahooBars(_ symbol: String, timeframe: Timeframe) async -> ChartPayload? {
        let request = timeframe.yahoo
        for host in yahooHosts {
            guard let url = URL(string: "https://\(host)/v8/finance/chart/\(escape(symbol))?range=\(request.range)&interval=\(request.interval)&includePrePost=\(timeframe.isIntraday)"),
                  let data = await get(url) else { continue }
            if let payload = await offMain({ Parse.yahooChart(data, symbol: symbol) }), !payload.bars.isEmpty { return payload }
        }
        return nil
    }

    /// Yahoo predefined screeners (day_gainers, day_losers, most_actives, small_cap_gainers).
    static func yahooScreener(_ id: String, count: Int = 50) async -> [ScanRow]? {
        var parts = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/screener/predefined/saved")!
        parts.queryItems = [URLQueryItem(name: "scrIds", value: id), URLQueryItem(name: "count", value: String(count))]
        guard let url = parts.url, let data = await get(url) else { return nil }
        let rows = await offMain { ScannerParse.yahoo(data) }
        return rows.isEmpty ? nil : rows
    }

    static func alpacaMovers(_ c: AlpacaCredentials) async -> (gainers: [ScanRow], losers: [ScanRow])? {
        guard let url = URL(string: "https://data.alpaca.markets/v1beta1/screener/stocks/movers?top=50"),
              let data = await get(url, headers: alpacaHeaders(c)) else { return nil }
        return await offMain { ScannerParse.alpacaMovers(data) }
    }

    static func alpacaActives(_ c: AlpacaCredentials) async -> [(symbol: String, volume: Double)]? {
        guard let url = URL(string: "https://data.alpaca.markets/v1beta1/screener/stocks/most-actives?by=volume&top=50"),
              let data = await get(url, headers: alpacaHeaders(c)) else { return nil }
        let rows = await offMain { ScannerParse.alpacaActives(data).map { ActiveRow(symbol: $0.symbol, volume: $0.volume) } }
        return rows.map { ($0.symbol, $0.volume) }
    }
    private struct ActiveRow: Sendable { let symbol: String; let volume: Double }

    static func earnings(_ symbol: String) async -> [EarningsDate]? {
        guard let data = await get(AppConfig.api("market/earnings/\(escape(symbol))")) else { return nil }
        return await offMain { Parse.earnings(data) }
    }

    /// Bars between two dates (for historical event replays). Yahoo uses Unix seconds.
    static func yahooBars(_ symbol: String, from: Date, to: Date, interval: String = "1d") async -> [Bar]? {
        let p1 = Int(from.timeIntervalSince1970), p2 = Int(to.timeIntervalSince1970)
        for host in yahooHosts {
            guard let url = URL(string: "https://\(host)/v8/finance/chart/\(escape(symbol))?period1=\(p1)&period2=\(p2)&interval=\(interval)"),
                  let data = await get(url) else { continue }
            if let payload = await offMain({ Parse.yahooChart(data, symbol: symbol) }), !payload.bars.isEmpty { return payload.bars }
        }
        return nil
    }

    /// Company profile and annual revenue/net income from the Trading Lab server (Finnhub).
    static func companyFinancials(_ symbol: String) async -> CompanyFinancials? {
        guard let data = await get(AppConfig.api("market/financials/\(escape(symbol))")) else { return nil }
        return await offMain { try? JSONDecoder().decode(CompanyFinancials.self, from: data) }
    }

    /// Alpaca OAuth app details from the Trading Lab server, when it's configured.
    static func alpacaOAuthConfig() async -> (clientID: String, redirectURI: String)? {
        guard let data = await get(AppConfig.api("brokers/alpaca/config")),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = o["clientId"] as? String, let redirect = o["redirectUri"] as? String else { return nil }
        return (id, redirect)
    }

    static func yahooSearch(_ query: String) async -> [SearchResult]? {
        var parts = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "quotesCount", value: "15"),
                            URLQueryItem(name: "newsCount", value: "0")]
        guard let url = parts.url, let data = await get(url) else { return nil }
        return await offMain { Parse.yahooSearchQuotes(data) }
    }

    static func yahooNews(_ symbol: String) async -> [NewsArticle] {
        var parts = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: symbol), URLQueryItem(name: "newsCount", value: "12"),
                            URLQueryItem(name: "quotesCount", value: "0")]
        guard let url = parts.url, let data = await get(url) else { return [] }
        return await offMain { Parse.yahooNews(data, symbol: symbol) }
    }

    /// Validates a ticker by asking for its chart. US-dollar stocks, ETFs and indexes only.
    static func lookupSecurity(_ input: String) async -> Security? {
        let symbol = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard symbol.range(of: "^[A-Z^][A-Z0-9.^-]{0,11}$", options: .regularExpression) != nil,
              let payload = await yahooChart(symbol, range: "5d", interval: "1d"),
              payload.currency == "USD", let kind = Parse.securityKind(yahooType: payload.instrumentType) else { return nil }
        return Security(symbol: symbol, name: payload.name ?? symbol, kind: kind,
                        description: kind == .index ? "A market index for comparison; it cannot be traded directly in this practice account."
                                                    : "Research the business or fund and write a plan before placing a virtual order.",
                        sector: kind == .index ? "Market index" : "US market")
    }

    // MARK: Trading Lab server

    static func fundamentals(_ symbol: String) async -> Fundamentals? {
        guard let data = await get(AppConfig.api("market/fundamentals/\(escape(symbol))")) else { return nil }
        return await offMain { Parse.fundamentals(data) }
    }

    // MARK: Alpaca (user's own market-data keys)

    struct AlpacaCredentials: Sendable { let key: String; let secret: String }
    static var alpacaCredentials: AlpacaCredentials? {
        guard let key = Keychain.read(.alpacaKey), let secret = Keychain.read(.alpacaSecret) else { return nil }
        return AlpacaCredentials(key: key, secret: secret)
    }
    private static func alpacaHeaders(_ c: AlpacaCredentials) -> [String: String] {
        ["APCA-API-KEY-ID": c.key, "APCA-API-SECRET-KEY": c.secret]
    }

    struct Snapshot: Sendable { let price: Double; let time: Date; let previousClose: Double? }
    static func alpacaSnapshot(_ symbol: String, _ c: AlpacaCredentials) async -> Snapshot? {
        guard let url = URL(string: "https://data.alpaca.markets/v2/stocks/\(escape(symbol))/snapshot?feed=iex"),
              let data = await get(url, headers: alpacaHeaders(c)) else { return nil }
        guard let parsed = await offMain({ Parse.alpacaSnapshot(data).map { Snapshot(price: $0.price, time: $0.time, previousClose: $0.previousClose) } }) else { return nil }
        return parsed
    }

    static func alpacaNews(_ symbols: [String], _ c: AlpacaCredentials) async -> [NewsArticle]? {
        var parts = URLComponents(string: "https://data.alpaca.markets/v1beta1/news")!
        parts.queryItems = [URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
                            URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "sort", value: "desc")]
        guard let url = parts.url, let data = await get(url, headers: alpacaHeaders(c)) else { return nil }
        return await offMain { Parse.alpacaNews(data) }
    }

    static func googleNewsRSS(_ symbols: [String]) async -> [NewsArticle]? {
        var parts = URLComponents(string: "https://news.google.com/rss/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: symbols.map { "\($0) stock" }.joined(separator: " OR ") + " when:1d"),
                            URLQueryItem(name: "hl", value: "en-US"), URLQueryItem(name: "gl", value: "US"),
                            URLQueryItem(name: "ceid", value: "US:en")]
        guard let url = parts.url, let data = await get(url) else { return nil }
        return await offMain { RSSReader.parse(data) }
    }
}

nonisolated final class RSSReader: NSObject, XMLParserDelegate {
    private var articles: [NewsArticle] = []
    private var inItem = false
    private var field = ""
    private var title = "", link = "", source = "", published = "", image = ""
    private let dateFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return format
    }()

    static func parse(_ data: Data) -> [NewsArticle]? {
        let reader = RSSReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        return parser.parse() ? Array(reader.articles.prefix(25)) : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        field = elementName
        if elementName == "item" { inItem = true; title = ""; link = ""; source = ""; published = ""; image = "" }
        if inItem, ["media:thumbnail", "media:content", "enclosure"].contains(elementName), let url = attributes["url"], image.isEmpty { image = url }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch field {
        case "title": title += string
        case "link": link += string
        case "source": source += string
        case "pubDate": published += string
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", !title.isEmpty {
                let imageURL = URL(string: image).flatMap { $0.scheme == "https" ? $0 : nil }
                articles.append(NewsArticle(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                            source: source.isEmpty ? "Google News" : source.trimmingCharacters(in: .whitespacesAndNewlines),
                                            date: dateFormat.date(from: published.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date(),
                                            url: url, imageURL: imageURL))
            }
            inItem = false
        }
        field = ""
    }
}
