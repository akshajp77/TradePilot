import SwiftUI

enum QuoteMetric: String, CaseIterable {
    case percent = "Percent change", dollars = "Price change", marketCap = "Market cap"
    var next: QuoteMetric { switch self { case .percent: return .dollars; case .dollars: return .marketCap; case .marketCap: return .percent } }
}

struct QuoteMetricBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var market: MarketData
    let symbol: String
    @AppStorage(PreferenceKeys.quoteMetric) private var metricName = QuoteMetric.percent.rawValue
    private var metric: QuoteMetric { QuoteMetric(rawValue: metricName) ?? .percent }

    private var text: String {
        switch metric {
        case .percent: return market.change(symbol).map { String(format: "%+.2f%%", $0) } ?? "—"
        case .dollars:
            guard let price = market.price(symbol), let close = market.previousClose(symbol) else { return "—" }
            return String(format: "%+.2f", price - close)
        case .marketCap:
            return market.statistics[symbol]?.marketCap.map { "$" + $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) } ?? "—"
        }
    }

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { metricName = metric.next.rawValue }
        } label: {
            Text(text).font(theme.label).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .contentTransition(.numericText()).frame(width: 72, height: 26)
                .foregroundStyle(.white)
                .background(theme.movement((market.change(symbol) ?? 0) >= 0), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(symbol), \(metric.rawValue), \(text)")
            .accessibilityHint("Switch to \(metric.next.rawValue.lowercased())")
            .help("Click to switch between percent change, price change, and market cap")
            .task(id: metricName + symbol) { if metric == .marketCap { await market.loadFundamentals(symbol) } }
    }
}

struct MarketRow: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: LabStore
    let item: Security
    @ObservedObject var market: MarketData
    var browseOrder: [String]? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.s12) {
                Button { store.openStock(item, order: browseOrder) } label: {
                    HStack(alignment: .center, spacing: Space.s12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.symbol).font(theme.body.weight(.semibold)).tracking(0.2).holdToExplainSymbol(item.symbol)
                            Text(item.name).font(theme.meta).foregroundStyle(theme.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        MarketSparkline(market: market, symbol: item.symbol).frame(width: 68)
                    }.foregroundStyle(theme.ink).frame(minHeight: 58).contentShape(Rectangle())
                }.buttonStyle(.plain).layoutPriority(1)
                VStack(alignment: .trailing, spacing: 6) {
                    Button { store.openStock(item, order: browseOrder) } label: {
                        Text(market.price(item.symbol)?.formatted(.number.precision(.fractionLength(2))) ?? "—")
                            .font(theme.body.weight(.medium)).monospacedDigit().foregroundStyle(theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.7).frame(width: 84, alignment: .trailing)
                            .holdToExplain("Last price", value: market.price(item.symbol).map { Format.price($0) } ?? "—", symbol: item.symbol)
                    }.buttonStyle(.plain)
                    QuoteMetricBadge(market: market, symbol: item.symbol)
                }.frame(width: 84, alignment: .trailing)
            }.padding(.vertical, 12)
            Rule()
        }
        .task(id: item.symbol) { if store.liveServices { await market.loadSeries(item.symbol, range: .day) } }
    }
}

struct PortfolioSwitcher: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s8) {
                ForEach(store.portfolios) { portfolio in
                    let active = portfolio.id == store.activePortfolioID
                    Button { store.switchPortfolio(portfolio.id) } label: {
                        HStack(spacing: 6) {
                            if active { Circle().fill(theme.accent).frame(width: 5, height: 5) }
                            Text(portfolio.title).font(theme.label).lineLimit(1)
                        }.padding(.horizontal, Space.s12).frame(height: 36)
                            .foregroundStyle(active ? theme.ink : theme.muted)
                            .background(active ? theme.surface : theme.line.opacity(0.22), in: Capsule())
                            .overlay(Capsule().stroke(active ? theme.accent.opacity(0.4) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(portfolio.title + (active ? ", active portfolio" : ""))
                }
                NavigationLink { PortfolioManagerView(store: store) } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36)
                        .foregroundStyle(theme.accent).background(theme.surface, in: Circle())
                }.accessibilityLabel("Manage portfolios")
            }
        }.accessibilityLabel("Practice portfolios")
    }
}

struct PortfolioManagerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var title = ""
    @State private var balance = "100000"
    @State private var deleting: Portfolio?

    var body: some View {
        Form {
            Section("Your portfolios") {
                ForEach(store.portfolios) { portfolio in
                    HStack {
                        Text(portfolio.title)
                        Spacer()
                        Button(portfolio.id == store.activePortfolioID ? "Active" : "Switch") { store.switchPortfolio(portfolio.id) }
                            .disabled(portfolio.id == store.activePortfolioID)
                    }
                    .swipeActions {
                        if portfolio.id != Portfolio.primaryID && portfolio.id != store.activePortfolioID {
                            Button("Delete", role: .destructive) { deleting = portfolio }
                        }
                    }
                    .contextMenu {
                        if portfolio.id != Portfolio.primaryID && portfolio.id != store.activePortfolioID {
                            Button("Delete portfolio", role: .destructive) { deleting = portfolio }
                        }
                    }
                }
                Text("Each portfolio has its own cash, positions, orders and journal. All of them sync when you are signed in; your public record, if on, uses the main portfolio.")
                    .font(theme.meta)
            }
            Section("Create portfolio") {
                TextField("Name, e.g. Long-term", text: $title)
                TextField("Starting virtual cash", text: $balance).appNumberKeyboard(.decimal)
                Button("Create portfolio") {
                    if let amount = DecimalInput.positive(balance) {
                        store.createPortfolio(title: title.trimmingCharacters(in: .whitespacesAndNewlines), balance: amount)
                        title = ""
                    }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || DecimalInput.positive(balance) == nil)
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Portfolios")
        .confirmationDialog("Delete \(deleting?.title ?? "portfolio")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete portfolio", role: .destructive) { if let deleting { store.deletePortfolio(deleting.id) }; deleting = nil }
        } message: { Text("Its orders, positions and journal notes are removed from every synced device.") }
    }
}

struct TodayTools: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            FeatureLink(title: "Alerts", detail: "\(store.features.alerts.filter { $0.triggeredAt == nil || $0.repeats }.count) armed") { AlertsView(store: store) }
            FeatureLink(title: "Portfolio review") { PortfolioReviewView(store: store, market: store.market) }
            DisclosureGroup("More tools") {
                FeatureLink(title: "Discover & compare") { ScreenerView(store: store, market: store.market) }
                if store.features.todaySections.contains(.learning) {
                    FeatureLink(title: "Continue learning") { GuidedPracticeView(store: store).learningTheme() }
                }
                if store.features.todaySections.contains(.events) {
                    let upcoming = store.features.events.filter { $0.date >= Calendar.current.startOfDay(for: Date()) }.count
                    FeatureLink(title: "Your event calendar", detail: "\(upcoming) upcoming tracked events") { EventCalendarView(store: store) }
                }
            }.font(theme.label)
        }
    }
}

struct WatchlistSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    let market: MarketData
    @State private var selected = "main"
    @State private var sort = "Custom"

    private var list: NamedWatchlist? { store.features.watchlists.first { $0.id == selected } }
    private var items: [Security] {
        var found = (list?.symbols ?? store.data.watched).compactMap(store.security)
        if sort == "Symbol" { found.sort { $0.symbol < $1.symbol } }
        if sort == "Change" { found.sort { (market.change($0.symbol) ?? -.infinity) > (market.change($1.symbol) ?? -.infinity) } }
        let pinned = Set(list?.pinned ?? [])
        return found.filter { pinned.contains($0.symbol) } + found.filter { !pinned.contains($0.symbol) }
    }

    var body: some View {
        if store.features.todaySections.contains(.watchlists) {
            VStack(alignment: .leading, spacing: Space.s12) {
                HStack {
                    Menu {
                        Button("Main watchlist") { selected = "main" }
                        ForEach(store.features.watchlists) { item in Button(item.title) { selected = item.id } }
                    } label: { Text((list?.title ?? "Watchlist") + " ▾").font(theme.section) }
                    Spacer()
                    Menu(sort) { ForEach(["Custom", "Symbol", "Change"], id: \.self) { option in Button(option) { sort = option } } }.font(theme.meta)
                    NavigationLink("Edit") { WatchlistManagerView(store: store) }.font(theme.meta)
                }
                if items.isEmpty { Text("Add a market to this watchlist from Edit.").foregroundStyle(theme.muted) }
                let order = items.map(\.symbol)
                ForEach(items) { item in MarketRow(item: item, market: market, browseOrder: order) }
            }
            .onChange(of: store.features.watchlists.map(\.id)) { _, ids in
                if selected != "main" && !ids.contains(selected) { selected = "main" }
            }
        }
    }
}

struct WatchlistManagerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var title = ""
    var body: some View {
        Form {
            Section("Create watchlist") {
                TextField("Name", text: $title)
                Button("Create") {
                    store.createWatchlist(title.trimmingCharacters(in: .whitespacesAndNewlines))
                    title = ""
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(store.features.watchlists) { list in
                Section(list.title) {
                    ForEach(store.allSecurities) { item in
                        HStack {
                            Toggle(item.symbol, isOn: Binding(
                                get: { list.symbols.contains(item.symbol) },
                                set: { store.setWatchlist(list.id, symbol: item.symbol, included: $0) }))
                            if list.symbols.contains(item.symbol) {
                                Button(list.pinned.contains(item.symbol) ? "Unpin" : "Pin") { store.togglePin(list.id, symbol: item.symbol) }
                                    .font(theme.meta)
                            }
                        }
                    }
                    Button("Delete watchlist", role: .destructive) { store.deleteWatchlist(list.id) }
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Watchlists")
    }
}
