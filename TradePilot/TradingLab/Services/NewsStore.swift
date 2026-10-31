import Foundation
import Combine

/// The single news source for the whole app. Feeds are cached per symbol set, so Profile's
/// "stories today" count and the News tab read the same articles.
@MainActor
final class NewsStore: ObservableObject {
    struct Feed: Equatable {
        var articles: [NewsArticle] = []
        var status = "Loading stories…"
        var loading = false
        var loadedAt: Date?
    }

    @Published private(set) var feeds: [String: Feed] = [:]
    private var generations: [String: Int] = [:]
    private let ttl: TimeInterval = 300

    static func key(_ symbols: [String]) -> String {
        Array(Set(symbols.isEmpty ? ["SPY", "AAPL", "MSFT"] : symbols)).sorted().joined(separator: ",")
    }

    func feed(_ symbols: [String]) -> Feed { feeds[Self.key(symbols)] ?? Feed() }

    func todayCount(_ symbols: [String], now: Date = Date()) -> Int {
        feed(symbols).articles.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }.count
    }

    func load(_ requested: [String], force: Bool = false) async {
        let key = Self.key(requested)
        let symbols = key.split(separator: ",").map(String.init)
        if !force, let loaded = feeds[key]?.loadedAt, Date().timeIntervalSince(loaded) < ttl { return }
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        feeds[key, default: Feed()].loading = true
        defer { if generations[key] == generation { feeds[key]?.loading = false } }

        func commit(_ articles: [NewsArticle], _ status: String) {
            guard generations[key] == generation else { return }
            feeds[key] = Feed(articles: articles, status: status, loading: false, loadedAt: Date())
        }

        // Alpaca first when connected: it carries publisher summaries and exact ticker tags.
        if let credentials = Feeds.alpacaCredentials, let alpaca = await Feeds.alpacaNews(symbols, credentials), !alpaca.isEmpty {
            commit(alpaca, "Relevant stories · Alpaca News")
            return
        }
        let perSymbol = await concurrentMap(Array(symbols.prefix(8)), limit: AppConfig.fetchConcurrency) { symbol in
            await Feeds.yahooNews(symbol)
        }
        var seen = Set<String>()
        let yahoo = perSymbol.flatMap { $0 }.sorted { $0.date > $1.date }.filter { seen.insert($0.id).inserted }
        if !yahoo.isEmpty {
            commit(Array(yahoo.prefix(30)), "Relevant stories · Yahoo Finance")
            return
        }
        if let google = await Feeds.googleNewsRSS(symbols) {
            commit(google, google.isEmpty ? "No relevant stories today. Try again later." : "Relevant stories · Google News")
            return
        }
        guard generations[key] == generation else { return }
        var feed = feeds[key] ?? Feed()
        feed.status = feed.articles.isEmpty ? "News unavailable. Pull to retry." : "Offline · showing the last loaded stories"
        feeds[key] = feed
    }
}
