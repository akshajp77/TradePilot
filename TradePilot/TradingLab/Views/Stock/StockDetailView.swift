import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct StockChartFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct StockBrowserSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LabStore
    let initial: Security
    @State private var selected: String
    @State private var chartFrame = CGRect.zero
    @State private var forward = true
    private var symbols: [String] { store.stockBrowseOrder.isEmpty ? [initial.symbol] : store.stockBrowseOrder }

    init(store: LabStore, initial: Security) {
        self.store = store
        self.initial = initial
        _selected = State(initialValue: initial.symbol)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let item = store.security(selected) {
                    StockDetailView(store: store, market: store.market, item: item, close: { dismiss() })
                        .id(selected)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
                }
            }
            .coordinateSpace(name: "stockBrowser")
            .onPreferenceChange(StockChartFrameKey.self) { chartFrame = $0 }
            .appStockSwipe(chartFrame: chartFrame) { step($0) }
            .accessibilityAction(named: Text("Next stock")) { step(1) }
            .accessibilityAction(named: Text("Previous stock")) { step(-1) }
            .appHideRootBar()
        }
        .tint(theme.accent).font(theme.body).foregroundStyle(theme.ink)
        .background(theme.paper)
    }

    private func step(_ direction: Int) {
        guard symbols.count > 1, let next = StockSwipePolicy.nextSymbol(selected, in: symbols, direction: direction), next != selected else { return }
        forward = (symbols.firstIndex(of: next) ?? 0) > (symbols.firstIndex(of: selected) ?? 0)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { selected = next }
    }
}

struct StockDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var news: NewsStore
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    let item: Security
    var close: (() -> Void)? = nil
    @State private var ticketSide: OrderSide?
    @State private var range: ChartRange = .day
    @State private var inspection: ChartInspection?

    private var chartPoints: [PricePoint] { market.points(item.symbol, range: range) }
    private var reference: Double? { range.isIntraday ? market.previousClose(item.symbol) : chartPoints.first?.price }
    private var currentChange: Double? {
        let latest = range.isIntraday ? market.price(item.symbol) ?? chartPoints.last?.price : chartPoints.last?.price
        guard let latest, let reference, reference > 0 else { return nil }
        return latest - reference
    }
    private var movementColor: Color { theme.movement((currentChange ?? market.change(item.symbol) ?? 0) >= 0) }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                header
                priceBlock
                chartBlock
                Rule()
                StockStatsGrid(stats: market.statistics[item.symbol])
                DisclosureGroup("More statistics") {
                    let stats = market.statistics[item.symbol]
                    GlossaryStat(label: "P/E ratio", value: stats?.peRatio?.formatted(.number.precision(.fractionLength(2))) ?? "—")
                    GlossaryStat(label: "EPS (TTM)", value: stats?.eps.map(Format.money) ?? "—")
                    GlossaryStat(label: "Beta", value: stats?.beta?.formatted(.number.precision(.fractionLength(2))) ?? "—")
                    statRow("Previous close", market.previousClose(item.symbol).map(Format.money) ?? "—")
                    if let exchange = stats?.exchange { statRow("Exchange", exchange) }
                    Text("Fundamentals via the Trading Lab server (Finnhub). Missing values mean the source has none.")
                        .font(theme.meta).foregroundStyle(theme.muted).padding(.top, Space.s4)
                }.font(theme.label)
                Rule()
                HStack {
                    Eyebrow(text: item.kind.rawValue)
                    Spacer()
                    Text(item.sector).font(theme.meta).foregroundStyle(theme.muted)
                }
                Text(item.description).font(theme.body).lineSpacing(4)
                Rule()
                CompanyExplainer(market: market, item: item)
                if store.shares(item.symbol) != 0 { positionBlock }
                Rule()
                StockUserTools(store: store, item: item)
                stockNews
            }
        }
        .safeAreaInset(edge: .bottom) {
            if item.kind.tradable {
                HStack(spacing: Space.s12) {
                    ActionButton(title: "Buy") { ticketSide = .buy }
                    ActionButton(title: store.shares(item.symbol) > 0 ? "Sell" : "Sell short", secondary: true,
                                 disabled: store.shares(item.symbol) <= 0 && !store.settings.canShort) { ticketSide = .sell }
                    Button { store.openChart(item.symbol) } label: {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 18, weight: .medium))
                            .frame(width: 50, height: 50).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                    }.buttonStyle(.plain).accessibilityLabel("Open \(item.symbol) on the chart")
                }.padding(.horizontal, Space.s24).padding(.vertical, Space.s12)
                    .background(theme.paper).overlay(alignment: .top) { Rule() }
            }
        }
        .appHideRootBar()
        .tint(theme.accent)
        .sheet(item: $ticketSide) { side in
            OrderTicketView(context: store.ticketContext(item.symbol), side: side) { request, note in
                store.place(request, note: note) != nil
            }.environment(\.theme, theme)
        }
        .task(id: "\(item.symbol):\(range.rawValue)") { if store.liveServices { await market.loadSeries(item.symbol, range: range) } }
        .task(id: item.symbol) {
            guard store.liveServices else { return }
            async let stories: Void = news.load([item.symbol])
            async let fundamentals: Void = market.loadFundamentals(item.symbol)
            _ = await (stories, fundamentals)
        }
        .onChange(of: range) { _, _ in inspection = nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.symbol).font(theme.page.weight(.semibold)).tracking(-0.5).holdToExplainSymbol(item.symbol)
                Text(item.name).font(theme.label).foregroundStyle(theme.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { if let close { close() } else { dismiss() } } label: {
                Image(systemName: "chevron.down").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44).foregroundStyle(theme.muted)
            }.buttonStyle(.plain).accessibilityLabel("Collapse stock")
        }
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            AnimatedMoney(value: inspection?.endPrice ?? market.price(item.symbol), placeholder: "Price unavailable", font: theme.display)
                .tracking(-1).minimumScaleFactor(0.7).lineLimit(1)
                .holdToExplain(inspection == nil ? "Last price" : "Price", value: (inspection?.endPrice ?? market.price(item.symbol)).map { Format.money($0) } ?? "Price unavailable", symbol: item.symbol)
            if let delta = currentChange, let reference, reference > 0 {
                HStack(spacing: Space.s8) {
                    AnimatedMoney(value: delta, font: theme.label, showPlus: true)
                    AnimatedPercent(value: delta / reference * 100, suffix: " · \(range.rawValue)", font: theme.label)
                }.foregroundStyle(movementColor)
                .holdToExplain("Move", value: "\(Format.signedMoney(delta)) (\(String(format: "%+.2f%%", delta / reference * 100)))", symbol: item.symbol, context: ["Measured over \(range.rawValue)."], tone: movementColor)
            }
            Text(market.quoteLabel(item.symbol)).font(theme.meta).foregroundStyle(theme.muted)
        }
    }

    @ViewBuilder private var chartBlock: some View {
        if !chartPoints.isEmpty {
            InteractiveLineChart(points: chartPoints, baseline: range.isIntraday ? market.previousClose(item.symbol) : nil,
                                 title: "\(item.symbol) price", range: $range,
                                 onInspectionChange: { inspection = $0 }, stockStyle: true, chartHeight: 260)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: StockChartFrameKey.self, value: geometry.frame(in: .named("stockBrowser")))
                    }
                }
                .id(range)
            if range.isIntraday, let previous = market.previousClose(item.symbol) {
                HStack(spacing: 6) {
                    DottedCloseKey(color: movementColor).frame(width: 18, height: 8)
                    Text("Previous close \(Format.money(previous))")
                    Spacer()
                    Text(inspection == nil ? "Drag to inspect" : "Release to return")
                }.font(theme.meta).foregroundStyle(theme.muted)
            }
        } else {
            ChartRangePicker(selection: $range)
            if market.isLoading(item.symbol, range: range) {
                ProgressView("Loading \(range.rawValue) prices…").frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Price history is unavailable for this range.").font(theme.label).foregroundStyle(theme.muted)
                    Button("Retry chart") { Task { await market.loadSeries(item.symbol, range: range, force: true) } }
                }.frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
            }
        }
    }

    private var positionBlock: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Rule()
            Text("Your position").font(theme.section)
            let position = store.position(item.symbol)
            Text("\(position?.isShort == true ? "Short " : "")\(Format.shares(position?.size ?? 0)) shares · \(store.positionValue(item.symbol).map(Format.money) ?? "Value pending")")
                .font(theme.label)
            if let basis = store.costBasis(item.symbol), let average = position?.averagePrice {
                statRow("Cost basis", "\(Format.money(basis)) · \(Format.money(average)) avg")
            }
            if let today = store.todayReturn(item.symbol) {
                statRow("Today's return", Format.signedMoney(today)).foregroundStyle(theme.gain(today >= 0))
            }
            if let total = store.totalReturn(item.symbol) {
                statRow("Unrealized P&L", Format.signedMoney(total)).foregroundStyle(theme.gain(total >= 0))
            }
            let orders = store.workingOrders(item.symbol)
            if !orders.isEmpty {
                Eyebrow(text: "Working orders").padding(.top, Space.s8)
                OrdersBlotter(store: store, symbol: item.symbol)
            }
        }
    }

    private var stockNews: some View {
        let feed = news.feed([item.symbol])
        return VStack(alignment: .leading, spacing: Space.s12) {
            HStack {
                Text("Latest on \(item.symbol)").font(theme.section)
                Spacer()
                if feed.loading { ProgressView() }
            }
            if feed.articles.isEmpty && !feed.loading {
                Text("No recent articles found for \(item.symbol).").font(theme.label).foregroundStyle(theme.muted)
            }
            ForEach(feed.articles.prefix(3)) { article in NewsArticleRow(article: article, focusSymbol: item.symbol) }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(theme.muted); Spacer(); Text(value).monospacedDigit() }
            .font(theme.label).padding(.vertical, Space.s8)
    }
}

extension OrderSide: Identifiable { var id: String { rawValue } }

struct StockStatsGrid: View {
    @Environment(\.theme) private var theme
    let stats: StockStatistics?
    private func number(_ value: Double?) -> String { value?.formatted(.number.precision(.fractionLength(2))) ?? "—" }
    private var rows: [(String, String)] {
        [("Open", number(stats?.open)), ("High", number(stats?.high)), ("Low", number(stats?.low)),
         ("Volume", stats?.volume?.formatted(.number.notation(.compactName)) ?? "—"),
         ("Market cap", stats?.marketCap.map { "$" + $0.formatted(.number.notation(.compactName)) } ?? "—"),
         ("P/E ratio", number(stats?.peRatio)),
         ("52W high", number(stats?.fiftyTwoWeekHigh)), ("52W low", number(stats?.fiftyTwoWeekLow)),
         ("Dividend yield", stats?.dividendYield?.formatted(.percent.precision(.fractionLength(2))) ?? "—")]
    }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: Space.s16) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(theme.meta).foregroundStyle(theme.muted).lineLimit(1)
                    Text(row.1).font(theme.label).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct GlossaryStat: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack { Text(label).underline(color: theme.line); Spacer(); Text(value).monospacedDigit() }
                .font(theme.label).foregroundStyle(theme.ink).padding(.vertical, Space.s8)
        }.buttonStyle(.plain)
            .sheet(isPresented: $showing) {
                NavigationStack {
                    Page {
                        VStack(alignment: .leading, spacing: Space.s16) {
                            if let entry = Curriculum.glossary.first(where: { $0.term == label }) {
                                Text(entry.term).font(theme.page)
                                Text(entry.explanation)
                                Rule(); Eyebrow(text: "Example"); Text(entry.example)
                            }
                        }
                    }.navigationTitle("Explain this term").appInlineTitle()
                        .toolbar { ToolbarItem { Button("Close") { showing = false } } }
                }.environment(\.theme, theme)
            }
    }
}

struct StockUserTools: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    let item: Security
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Button(store.data.watched.contains(item.symbol) ? "Remove from watchlist" : "Add to watchlist") { store.toggleWatch(item.symbol) }
                .font(theme.label).buttonStyle(.plain).foregroundStyle(theme.accent).padding(.vertical, Space.s8)
            FeatureLink(title: "Research notebook") { ResearchLibraryView(store: store, focus: item.symbol) }
            DisclosureGroup("More tools") {
                if item.kind.tradable {
                    FeatureLink(title: "Recurring investment") { RecurringInvestmentView(store: store, symbol: item.symbol) }
                }
                FeatureLink(title: "Price alerts & events") { EventCalendarView(store: store, initialSymbol: item.symbol) }
                FeatureLink(title: "Compare price history") { MarketComparisonView(store: store, market: store.market, first: item.symbol) }
            }.font(theme.label)
        }
    }
}

// MARK: - Swipe between stocks

enum StockSwipePolicy {
    static func direction(start: CGPoint, translation: CGSize, chart: CGRect) -> Int? {
        guard start.y > 44, !chart.contains(start), abs(translation.width) > 70,
              abs(translation.width) > abs(translation.height) * 1.7 else { return nil }
        return translation.width < 0 ? 1 : -1
    }
    static func nextSymbol(_ current: String, in symbols: [String], direction: Int) -> String? {
        guard let index = symbols.firstIndex(of: current) else { return nil }
        let next = index + direction
        return symbols.indices.contains(next) ? symbols[next] : nil
    }
}

extension View {
    @ViewBuilder func appStockSwipe(chartFrame: CGRect, move: @escaping (Int) -> Void) -> some View {
        #if os(iOS)
        self.background(StockSwipeInstaller(chartFrame: chartFrame, move: move))
        #else
        self.simultaneousGesture(DragGesture(minimumDistance: 35, coordinateSpace: .named("stockBrowser")).onEnded { gesture in
            if let direction = StockSwipePolicy.direction(start: gesture.startLocation, translation: gesture.translation, chart: chartFrame) { move(direction) }
        })
        #endif
    }
}

#if os(iOS)
private struct StockSwipeInstaller: UIViewRepresentable {
    let chartFrame: CGRect
    let move: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> StockSwipeAnchor {
        let view = StockSwipeAnchor()
        view.isUserInteractionEnabled = false
        view.install = { [weak coordinator = context.coordinator] anchor in coordinator?.attach(anchor) }
        return view
    }
    func updateUIView(_ view: StockSwipeAnchor, context: Context) {
        context.coordinator.chart = chartFrame
        context.coordinator.move = move
        context.coordinator.attach(view)
    }
    static func dismantleUIView(_ view: StockSwipeAnchor, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var anchor: UIView?
        weak var target: UIView?
        var chart = CGRect.zero
        var move: (Int) -> Void = { _ in }
        var initial = CGPoint.zero
        lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()
        func attach(_ view: UIView) {
            guard let parent = view.superview else { return }
            anchor = view
            if target !== parent { remove(); target = parent; parent.addGestureRecognizer(pan) }
        }
        func remove() { target?.removeGestureRecognizer(pan); target = nil }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let anchor else { return false }
            let velocity = pan.velocity(in: anchor)
            return initial.y > 44 && !chart.contains(initial) && abs(velocity.x) > abs(velocity.y) * 1.7
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let anchor else { return false }
            let point = touch.location(in: anchor)
            guard anchor.bounds.contains(point), point.y > 44, !chart.contains(point) else { return false }
            initial = point
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func handle(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let anchor else { return }
            let delta = recognizer.translation(in: anchor)
            if let direction = StockSwipePolicy.direction(start: initial, translation: CGSize(width: delta.x, height: delta.y), chart: chart) { move(direction) }
        }
    }
}

private final class StockSwipeAnchor: UIView {
    var install: ((UIView) -> Void)?
    override func didMoveToSuperview() { super.didMoveToSuperview(); install?(self) }
    override func didMoveToWindow() { super.didMoveToWindow(); install?(self) }
}
#endif
