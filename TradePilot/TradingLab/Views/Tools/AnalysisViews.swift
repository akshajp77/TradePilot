import SwiftUI
import Charts

struct PortfolioReviewView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @State private var shock = -10.0
    @State private var target = "ALL"

    var body: some View {
        let ledger = store.ledger
        let total = store.portfolioValue
        let positions = ledger.heldSymbols
        let realized = ledger.realized.map(\.gain)
        let winners = realized.filter { $0 > 0 }, losers = realized.filter { $0 < 0 }
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                Eyebrow(text: store.activeTitle)
                Text("Portfolio review").font(theme.page)
                if total != nil {
                    let unrealized = positions.reduce(Decimal(0)) { $0 + (store.totalReturn($1) ?? 0) }
                    ExplainRow("Unrealized return", value: Format.signedMoney(unrealized))
                } else {
                    Text("Unrealized return is waiting for position prices.").foregroundStyle(theme.muted)
                }
                ExplainRow("Realized return", value: Format.signedMoney(realized.reduce(0, +)))
                ExplainRow("Maximum recorded drawdown",
                               value: Ledger.maxDrawdown(store.portfolioHistory, start: store.startingBalance.double).formatted(.percent.precision(.fractionLength(1))))
                ExplainRow("Average winning sale", value: winners.isEmpty ? "—" : Format.money(winners.reduce(0, +) / Decimal(winners.count)))
                ExplainRow("Average losing sale", value: losers.isEmpty ? "—" : Format.money(losers.reduce(0, +) / Decimal(losers.count)))
                Text("Sale statistics use average cost; drawdown uses saved portfolio observations.").font(theme.meta).foregroundStyle(theme.muted)
                Rule()
                Text("Allocation").font(theme.section)
                if let total, total > 0 {
                    allocationRow("Cash", amount: store.cash, total: total)
                    ForEach(positions, id: \.self) { symbol in allocationRow(symbol, amount: store.positionValue(symbol) ?? 0, total: total) }
                    Text("By sector").font(theme.label)
                    let sectors = Dictionary(grouping: positions, by: { store.security($0)?.sector ?? "Other" })
                    ForEach(sectors.keys.sorted(), id: \.self) { sector in
                        allocationRow(sector, amount: (sectors[sector] ?? []).reduce(Decimal(0)) { $0 + (store.positionValue($1) ?? 0) }, total: total)
                    }
                } else { Text("Waiting for prices.").foregroundStyle(theme.muted) }
                Rule()
                Text("What if?").font(theme.section)
                Picker("Apply change to", selection: $target) {
                    Text("All positions").tag("ALL")
                    ForEach(positions, id: \.self) { Text($0).tag($0) }
                }
                Slider(value: $shock, in: -50...50, step: 1)
                Text("Price change: \(shock.formatted(.number.precision(.fractionLength(0))))%").font(theme.label)
                if let total {
                    let exposure = positions.filter { target == "ALL" || $0 == target }.reduce(Decimal(0)) { $0 + (store.positionValue($1) ?? 0) }
                    let change = (exposure * Decimal(shock) / 100).rounded(Precision.cash)
                    ExplainRow("Hypothetical portfolio", value: Format.money(total + change))
                    ExplainRow("Change in value", value: Format.signedMoney(change))
                }
                Text("Explore a scenario without placing an order. Cash and other positions remain constant.").font(theme.meta).foregroundStyle(theme.muted)
                Rule()
                BenchmarkSection(store: store, market: market)
            }
        }.navigationTitle("Review").appInlineTitle()
    }

    private func allocationRow(_ title: String, amount: Decimal, total: Decimal) -> some View {
        let share = (amount / total).double
        return VStack(alignment: .leading, spacing: Space.s4) {
            HStack { Text(title); Spacer(); Text(share.formatted(.percent.precision(.fractionLength(1)))).monospacedDigit() }.font(theme.label)
            GeometryReader { geometry in
                Rectangle().fill(theme.line).overlay(alignment: .leading) {
                    Rectangle().fill(theme.accent).frame(width: geometry.size.width * min(1, max(0, share)))
                }
            }.frame(height: 4)
        }
    }
}

struct BenchmarkSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @State private var range: ChartRange = .month

    private var matched: (portfolio: Double, spy: Double)? {
        let history = store.portfolioHistory.filter { $0.date >= range.start() }
        let spy = market.points("SPY", range: range)
        guard let first = history.first, let last = history.last, last.date > first.date,
              let a = spy.first(where: { $0.date >= first.date }), let b = spy.last(where: { $0.date <= last.date }), b.date > a.date,
              let p0 = history.first(where: { $0.date >= a.date }), let p1 = history.last(where: { $0.date <= b.date }), p1.date > p0.date,
              a.price > 0, p0.value > 0 else { return nil }
        return (p1.value / p0.value - 1, b.price / a.price - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Against SPY").font(theme.section)
            ChartRangePicker(selection: $range)
            if let result = matched {
                ExplainRow("Your portfolio", value: result.portfolio.formatted(.percent.precision(.fractionLength(2))))
                ExplainRow("SPY price return", value: result.spy.formatted(.percent.precision(.fractionLength(2))))
            } else {
                Text("Keep practicing to build enough overlapping history for a comparison.").foregroundStyle(theme.muted)
            }
            Text("Uses overlapping recorded dates. SPY price return excludes distributions.").font(theme.meta).foregroundStyle(theme.muted)
        }.task(id: range) { await market.loadSeries("SPY", range: range) }
    }
}

struct ScreenerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @State private var sector = "All"
    @State private var kind = "All"
    @State private var maximum = ""
    @State private var minimumCap = ""
    @State private var minimumYield = ""
    @State private var sort = "Symbol"
    @State private var adding = ""
    @State private var loading = false

    private var filtered: [Security] {
        let maxPrice = DecimalInput.positive(maximum)?.double
        let minCap = DecimalInput.positive(minimumCap)?.double
        let minYield = DecimalInput.positive(minimumYield)?.double
        var items = store.allSecurities.filter { item in
            guard sector == "All" || item.sector == sector, kind == "All" || item.kind.rawValue == kind else { return false }
            if let maxPrice { guard let price = market.price(item.symbol), price <= maxPrice else { return false } }
            if let minCap { guard let value = market.statistics[item.symbol]?.marketCap, value >= minCap * 1_000_000_000 else { return false } }
            if let minYield { guard let value = market.statistics[item.symbol]?.dividendYield, value >= minYield / 100 else { return false } }
            return true
        }
        switch sort {
        case "Price": items.sort { (market.price($0.symbol) ?? .infinity) < (market.price($1.symbol) ?? .infinity) }
        case "Change": items.sort { (market.change($0.symbol) ?? -.infinity) > (market.change($1.symbol) ?? -.infinity) }
        default: items.sort { $0.symbol < $1.symbol }
        }
        return items
    }

    var body: some View {
        let results = filtered
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Discover & compare").font(theme.page)
                Text("Screen your tracked markets. Add more tickers to broaden the list; missing statistics are excluded from their filters.").foregroundStyle(theme.muted)
                Picker("Sector", selection: $sector) {
                    Text("All").tag("All")
                    ForEach(Array(Set(store.allSecurities.map(\.sector))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Type", selection: $kind) {
                    Text("All").tag("All")
                    ForEach(SecurityKind.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                TextField("Maximum price ($), optional", text: $maximum).appNumberKeyboard(.decimal).inputField()
                TextField("Minimum market cap ($ billions), optional", text: $minimumCap).appNumberKeyboard(.decimal).inputField()
                TextField("Minimum dividend yield (%), optional", text: $minimumYield).appNumberKeyboard(.decimal).inputField()
                Picker("Sort", selection: $sort) { ForEach(["Symbol", "Price", "Change"], id: \.self) { Text($0) } }
                HStack {
                    TextField("Add ticker", text: $adding).appCapitalization(.characters).inputField()
                    Button(loading ? "Adding…" : "Add") {
                        loading = true
                        Task {
                            if await store.addSecurity(adding) { store.showToast("\(adding.uppercased()) added to Markets.") }
                            adding = ""; loading = false
                        }
                    }.disabled(loading || adding.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                FeatureLink(title: "Compare two markets") { MarketComparisonView(store: store, market: market) }
                Rule()
                Text("\(results.count) matches").font(theme.meta)
                ForEach(results) { item in MarketRow(item: item, market: market, browseOrder: results.map(\.symbol)) }
                if results.isEmpty { Text("No matches. Adjust the filters or add a ticker.").foregroundStyle(theme.muted) }
            }
        }
        .navigationTitle("Discover").appInlineTitle()
        .task { await market.loadFundamentals(store.allSecurities.filter { $0.kind != .index }.map(\.symbol)) }
    }
}

struct MarketComparisonView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @State private var first: String
    @State private var second: String
    @State private var range: ChartRange = .month

    init(store: LabStore, market: MarketData, first: String = "AAPL") {
        self.store = store
        self.market = market
        _first = State(initialValue: first)
        _second = State(initialValue: first == "SPY" ? "AAPL" : "SPY")
    }

    private struct Point: Identifiable {
        let symbol: String
        let date: Date
        let change: Double
        var id: String { symbol + String(date.timeIntervalSince1970) }
    }

    private var points: [Point] {
        let a = market.points(first, range: range), b = market.points(second, range: range)
        guard let aStart = a.first?.date, let bStart = b.first?.date, let aEnd = a.last?.date, let bEnd = b.last?.date else { return [] }
        let start = max(aStart, bStart), end = min(aEnd, bEnd)
        return [(first, a), (second, b)].flatMap { pair -> [Point] in
            let (symbol, series) = pair
            let samples = series.filter { $0.date >= start && $0.date <= end }
            guard let initial = samples.first?.price, initial > 0 else { return [] }
            return samples.map { Point(symbol: symbol, date: $0.date, change: ($0.price / initial - 1) * 100) }
        }
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Compare markets").font(theme.page)
                Picker("First", selection: $first) { ForEach(store.allSecurities) { Text($0.symbol).tag($0.symbol) } }
                Picker("Second", selection: $second) { ForEach(store.allSecurities) { Text($0.symbol).tag($0.symbol) } }
                ChartRangePicker(selection: $range)
                if first == second { Text("Choose two different markets.").foregroundStyle(theme.muted) }
                else if points.isEmpty { Text("Waiting for overlapping price history.").foregroundStyle(theme.muted) }
                else {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Change (%)", point.change), series: .value("Market", point.symbol))
                            .foregroundStyle(by: .value("Market", point.symbol))
                    }
                    .chartForegroundStyleScale(domain: [first, second], range: [theme.accent, theme.warning])
                    .frame(height: 240)
                    Text("Both series start at 0% over overlapping dates. Prices exclude distributions.").font(theme.meta).foregroundStyle(theme.muted)
                }
            }
        }
        .navigationTitle("Compare").appInlineTitle()
        .task(id: first + second + range.rawValue) {
            async let a: Void = market.loadSeries(first, range: range)
            async let b: Void = market.loadSeries(second, range: range)
            _ = await (a, b)
        }
    }
}

struct RecurringInvestmentView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    let symbol: String
    @State private var dollars = "100"
    @State private var days = 7
    @State private var firstDate = Date()
    private var schedules: [ScheduledInvestment] {
        store.features.recurring.filter { $0.symbol == symbol && $0.portfolio == store.activePortfolioID }
    }

    var body: some View {
        Form {
            Section("Schedule virtual purchases") {
                Text("\(symbol) · \(store.activeTitle)").font(theme.label)
                TextField("Dollars per purchase", text: $dollars).appNumberKeyboard(.decimal)
                Picker("Frequency", selection: $days) { Text("Weekly").tag(7); Text("Every two weeks").tag(14); Text("Every 30 days").tag(30) }
                DatePicker("First purchase", selection: $firstDate, in: Date()..., displayedComponents: .date)
                Button("Create schedule") {
                    if let amount = DecimalInput.positive(dollars) { store.addSchedule(symbol: symbol, dollars: amount, intervalDays: days, firstDate: firstDate) }
                }.disabled(store.security(symbol)?.kind.tradable != true || DecimalInput.positive(dollars) == nil)
                Text("Purchases run while the app is open and a price from the last week is available. When the market is closed, the purchase is queued for the next open. Missed periods are skipped; nothing runs in the background.")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
            ForEach(schedules) { schedule in
                Section {
                    ExplainRow("Amount", value: Format.money(schedule.dollars))
                    ExplainRow("Next purchase", value: schedule.nextDate.formatted(date: .abbreviated, time: .omitted))
                    Text(schedule.lastMessage).font(theme.meta)
                    Toggle("Enabled", isOn: Binding(get: { schedule.enabled }, set: { store.setScheduleEnabled(schedule.id, $0) }))
                    Button("Delete schedule", role: .destructive) { store.deleteSchedule(schedule.id) }
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Recurring investment")
    }
}
