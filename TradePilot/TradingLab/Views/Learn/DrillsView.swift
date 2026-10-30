import SwiftUI

/// Chart-reading practice on real past charts. The symbol and dates are hidden until you answer,
/// so you read the chart instead of remembering the news.
struct DrillsView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    @State private var kind: DrillKind = .trend
    @State private var drill: Drill?
    @State private var timeframe: Timeframe = .d1
    @State private var loading = false
    @State private var result: DrillGrader.Result?
    @State private var tool: DrawingTool = .horizontal
    @State private var stopPrice: Double?
    @State private var rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970))
    @State private var streak = 0

    private static let universe = ["SPY", "QQQ", "AAPL", "MSFT", "NVDA", "AMZN", "TSLA", "META", "GOOGL", "JPM", "XOM", "KO", "DIS", "AMD", "NFLX", "WMT"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Picker("Drill", selection: $kind) { ForEach(DrillKind.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                HStack {
                    let box = store.learning.drills[kind.rawValue]
                    Text(box?.accuracy.map { "Accuracy \(Int($0 * 100))% over \(box?.attempts ?? 0)" } ?? "New drill")
                    Spacer()
                    if streak > 1 { Text("🔥 \(streak) in a row") }
                }.font(theme.meta).foregroundStyle(theme.muted)
                Text(kind.prompt).font(theme.section).fixedSize(horizontal: false, vertical: true)
                chart
                answers
                if let result {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Label(result.correct ? "Correct" : "Not quite", systemImage: result.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(theme.label).foregroundStyle(result.correct ? theme.accent : theme.loss)
                        Text(result.message).font(theme.body).fixedSize(horizontal: false, vertical: true)
                        if let drill { Text("This was \(drill.symbol), \(timeframe == .d1 ? "daily" : "5-minute") bars ending \(drill.bars.last?.time.formatted(date: .abbreviated, time: timeframe == .d1 ? .omitted : .shortened) ?? "").").font(theme.meta).foregroundStyle(theme.muted) }
                        ActionButton(title: "Next chart") { Task { await next() } }
                    }
                    .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                    .transition(.opacity)
                }
                Text("Drills come back on a schedule: miss one and it returns soon; get it right and it waits longer.")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
            .padding(Space.s16)
            .animation(.easeInOut(duration: 0.25), value: result?.message)
        }
        .background(theme.paper)
        .learningTheme()
        .navigationTitle("Chart drills").appInlineTitle()
        .task(id: kind) { await next() }
    }

    @ViewBuilder private var chart: some View {
        if let drill {
            ProChartView(data: .build(bars: drill.bars, timeframe: timeframe, preferences: drillPrefs, previousClose: nil, hours: store.market.hours),
                         style: .candles, showVolume: true, resetKey: drill.id.uuidString,
                         drawings: stopPrice.map { [ChartDrawing(symbol: "drill", kind: .horizontal(price: $0), colorIndex: 1)] } ?? [],
                         tool: Binding(get: { kind == .stop && result == nil ? tool : nil }, set: { tool = $0 ?? .horizontal }),
                         magnet: false,
                         onAddDrawing: { drawing in
                             if case .horizontal(let price) = drawing, result == nil {
                                 stopPrice = price
                                 grade(stop: price)
                             }
                         })
                .frame(height: 300)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        } else {
            VStack(spacing: Space.s8) {
                ProgressView()
                Text(loading ? "Finding a chart…" : "Couldn't load a chart. Check your connection.").font(theme.meta).foregroundStyle(theme.muted)
                if !loading { Button("Try again") { Task { await next() } } }
            }.frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @ViewBuilder private var answers: some View {
        if kind == .stop {
            Text(result == nil ? "Tap the chart at the price for your stop loss." : "Your stop: \(stopPrice.map(Format.price) ?? "—")")
                .font(theme.meta).foregroundStyle(theme.muted)
        } else if drill != nil {
            HStack(spacing: Space.s8) {
                ForEach(kind.options.indices, id: \.self) { i in
                    ActionButton(title: kind.options[i], secondary: true, disabled: result != nil) { grade(choice: i) }
                }
            }
        }
    }

    private var drillPrefs: ChartPreferences {
        var p = ChartPreferences()
        p.indicators = kind == .trend ? [IndicatorConfig(kind: .sma, length: 20, colorIndex: 1)] : []
        p.showExtendedHours = false
        return p
    }

    private func grade(choice: Int? = nil, stop: Double? = nil) {
        guard let drill else { return }
        let r = DrillGrader.grade(drill, choice: choice, stopPrice: stop)
        result = r
        streak = r.correct ? streak + 1 : 0
        store.recordDrill(kind, correct: r.correct)
    }

    private func next() async {
        loading = true
        defer { loading = false }
        result = nil; stopPrice = nil
        for _ in 0..<4 {
            let symbol = Self.universe.randomElement(using: &rng) ?? "SPY"
            let tf: Timeframe = Bool.random(using: &rng) ? .d1 : .m5
            if store.market.candles(symbol, tf).count < 120 { await store.market.loadBars(symbol, timeframe: tf) }
            var bars = store.market.candles(symbol, tf)
            if tf == .m5 { bars = bars.filter { store.market.hours.isRegularSessionPrint($0.time) } }
            if let made = DrillFactory.make(kind, symbol: symbol, bars: bars, rng: &rng) {
                timeframe = tf
                drill = made
                return
            }
        }
        drill = nil
    }
}
