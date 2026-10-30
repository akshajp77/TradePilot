import SwiftUI
import Charts

/// Shows, with 1,000 simulated futures, how win rate, reward-to-risk and risk per trade decide
/// whether an account grows or blows up.
struct SizingLabView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    @State private var inputs = SizingSimulation.Inputs()
    @State private var result: SizingSimulation?
    @State private var running = false
    @State private var usedOwnStats = false

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Position-size lab").font(theme.page)
                    Text("Same trader, same skill, different bet sizes. Move the sliders and see 1,000 possible futures of \(inputs.trades) trades.")
                        .foregroundStyle(theme.muted)
                }
                if let mine = ownStats {
                    Button(usedOwnStats ? "Using your practice results" : "Use my practice results (\(mine.trades) trades)") {
                        inputs.winRate = mine.winRate; inputs.winR = mine.winR
                        usedOwnStats = true
                    }.font(theme.label).disabled(usedOwnStats)
                }
                VStack(alignment: .leading, spacing: Space.s12) {
                    slider("How often you win", value: $inputs.winRate, range: 0.2...0.8, step: 0.01, text: "\(Int(inputs.winRate * 100))%", term: "Win rate")
                    slider("Average win vs average loss", value: $inputs.winR, range: 0.5...4, step: 0.1, text: String(format: "%.1f to 1", inputs.winR), term: "Reward-to-risk")
                    slider("Risk per trade", value: $inputs.riskFraction, range: 0.005...0.2, step: 0.005, text: String(format: "%.1f%% of account", inputs.riskFraction * 100), term: "Position sizing")
                }
                if let r = result {
                    let edge = r.expectancyR
                    Text(edge > 0 ? "On average each trade makes \(String(format: "%.2f", edge))× what you risk. That's a real edge, so sizing decides how bumpy the ride is."
                         : "On average each trade loses \(String(format: "%.2f", -edge))× what you risk. No position size can fix a losing approach; smaller sizes only lose more slowly.")
                        .font(theme.label).foregroundStyle(edge > 0 ? theme.ink : theme.loss)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Space.s16) {
                        stat("Typical result", Format.money(r.medianEnding), sub: "from \(Format.money(r.inputs.startingBalance))")
                        stat("Chance of losing half", "\(Int((r.ruinProbability * 100).rounded()))%", sub: "at some point", warn: r.ruinProbability > 0.05)
                        stat("Unlucky 1 in 10", Format.money(r.worstTenth), sub: "ending balance")
                        stat("Typical worst dip", "\(Int((r.medianMaxDrawdown * 100).rounded()))%", sub: "from a high", warn: r.medianMaxDrawdown > 0.3)
                    }
                    Chart {
                        ForEach(Array(r.samplePaths.enumerated()), id: \.offset) { path in
                            ForEach(Array(path.element.enumerated()), id: \.offset) { point in
                                LineMark(x: .value("Trade", point.offset), y: .value("Balance", point.element), series: .value("Path", path.offset))
                                    .foregroundStyle(theme.accent.opacity(0.35 + 0.12 * Double(path.offset)))
                                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                            }
                        }
                        RuleMark(y: .value("Start", r.inputs.startingBalance)).foregroundStyle(theme.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartXAxisLabel("Trade number")
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Format.compact(d)) } } } }
                    .frame(height: 220)
                    .accessibilityLabel("Five example account paths")
                    Text("Even with these exact odds, expect a losing streak of about \(SizingSimulation.typicalLosingStreak(winRate: inputs.winRate, trades: inputs.trades)) trades in a row somewhere in \(inputs.trades) trades. Your size should make that streak survivable.")
                        .font(theme.meta).foregroundStyle(theme.muted)
                } else if running {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .learningTheme()
        .navigationTitle("Position-size lab").appInlineTitle()
        .task(id: inputs) { await run() }
        .onAppear { store.recordAction("sizingLab") }
    }

    private var ownStats: (trades: Int, winRate: Double, winR: Double)? {
        let stats = TradeAnalytics.stats(store.roundTrips)
        guard stats.trades >= 10, let rate = stats.winRate, let win = stats.averageWin, let loss = stats.averageLoss, loss < 0 else { return nil }
        return (stats.trades, min(0.8, max(0.2, rate)), min(4, max(0.5, (win / -loss).double)))
    }

    private func run() async {
        running = true
        let snapshot = inputs
        try? await Task.sleep(for: .milliseconds(150))   // debounce slider drags
        guard snapshot == inputs else { return }
        result = await offMain { SizingSimulation.run(snapshot) }
        running = false
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String, term: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(theme.label)
                ExplainButton(term: term)
                Spacer()
                Text(text).font(theme.label.monospacedDigit()).foregroundStyle(theme.accent)
            }
            Slider(value: value, in: range, step: step).onChange(of: value.wrappedValue) { _, _ in usedOwnStats = false }
        }
    }

    private func stat(_ title: String, _ value: String, sub: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(theme.meta).foregroundStyle(theme.muted)
            Text(value).font(theme.section.monospacedDigit()).foregroundStyle(warn ? theme.loss : theme.ink)
            Text(sub).font(theme.meta).foregroundStyle(theme.muted)
        }
    }
}

/// Long-term investing with real S&P 500 (SPY) prices, compared with what frequent trading costs.
struct InvestingView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    @State private var monthly = 100.0
    @State private var years = 10
    @State private var tradesPerDay = 5.0
    @State private var positionSize = 5_000.0
    @State private var loading = false

    private var monthlyCloses: [(date: Date, close: Double)] {
        InvestingMath.monthlyCloses(store.market.candles("SPY", .w1), calendar: store.market.hours.calendar)
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Investing vs trading").font(theme.page)
                    Text("What steady investing in the S&P 500 actually did, using real past prices.").foregroundStyle(theme.muted)
                }
                VStack(alignment: .leading, spacing: Space.s12) {
                    HStack { Text("Invest each month").font(theme.label); Spacer(); Text(Format.money(monthly)).font(theme.label.monospacedDigit()).foregroundStyle(theme.accent).holdToExplain("Invest each month", value: Format.money(monthly), term: "Dollar-cost averaging", practice: false) }
                    Slider(value: $monthly, in: 25...1_000, step: 25)
                    Picker("Starting", selection: $years) { ForEach([3, 5, 10], id: \.self) { Text("\($0) years ago").tag($0) } }.pickerStyle(.segmented)
                }
                history
                Rule()
                VStack(alignment: .leading, spacing: Space.s12) {
                    HStack { Text("If you kept going for 30 years").font(theme.section); ExplainButton(term: "Compounding") }
                    let future = InvestingMath.compound(initial: 0, monthly: monthly, annualReturn: 0.08, years: 30)
                    Text("At 8% a year (a bit below the S&P 500's long-run average, and never guaranteed), \(Format.money(monthly)) a month grows to about \(Format.money(future.value.rounded())) from \(Format.money(future.contributed)) put in.")
                        .fixedSize(horizontal: false, vertical: true)
                    ConceptGraphic(kind: "compound").frame(height: 140)
                }
                Rule()
                VStack(alignment: .leading, spacing: Space.s12) {
                    HStack { Text("What day trading costs").font(theme.section); ExplainButton(term: "Spread") }
                    HStack { Text("Trades a day"); Spacer(); Stepper("\(Int(tradesPerDay))", value: $tradesPerDay, in: 1...30).fixedSize() }
                    HStack { Text("Size of each trade"); Spacer(); Text(Format.money(positionSize)).monospacedDigit().holdToExplain("Size of each trade", value: Format.money(positionSize), term: "Position sizing", practice: false) }
                    Slider(value: $positionSize, in: 500...25_000, step: 500)
                    let cost = InvestingMath.tradingCosts(tradesPerDay: tradesPerDay, positionSize: positionSize, spreadBps: 3, slippageBps: 2, commissionPerTrade: 0)
                    Text("Even with free commissions, paying a small spread and a little slippage on every trade costs about \(Format.money(cost.rounded())) a year before you win or lose anything. You'd need to beat that just to break even.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Assumes a 0.03% spread and 0.02% slippage each way, typical for very liquid stocks. Smaller stocks cost much more.").font(theme.meta).foregroundStyle(theme.muted)
                }
                Text("Not financial advice. Past returns don't guarantee future returns. Dividends aren't included here, which makes the real investing results a bit better than shown.")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
        }
        .learningTheme()
        .navigationTitle("Investing vs trading").appInlineTitle()
        .task {
            store.recordAction("investingCalc")
            if store.market.candles("SPY", .w1).isEmpty { loading = true; await store.market.loadBars("SPY", timeframe: .w1); loading = false }
        }
    }

    @ViewBuilder private var history: some View {
        let cutoff = store.market.hours.calendar.date(byAdding: .year, value: -years, to: Date()) ?? Date()
        let prices = monthlyCloses.filter { $0.date >= cutoff }
        if prices.count > 6 {
            let result = InvestingMath.dollarCostAverage(prices: prices, monthly: monthly)
            let gain = result.value - result.contributed
            VStack(alignment: .leading, spacing: Space.s8) {
                Text("You'd have put in \(Format.money(result.contributed)) and it would be worth \(Format.money(result.value.rounded())) today.")
                    .font(theme.label).fixedSize(horizontal: false, vertical: true)
                Text("\(gain >= 0 ? "Gain" : "Loss") of \(Format.money(abs(gain).rounded())), without picking a single stock.").foregroundStyle(theme.gain(gain >= 0))
                Chart {
                    ForEach(Array(result.series.enumerated()), id: \.offset) { point in
                        AreaMark(x: .value("Date", point.element.date), y: .value("Value", point.element.value)).foregroundStyle(theme.accent.opacity(0.15))
                        LineMark(x: .value("Date", point.element.date), y: .value("Value", point.element.value), series: .value("Line", "Value")).foregroundStyle(theme.accent)
                        LineMark(x: .value("Date", point.element.date), y: .value("Put in", point.element.contributed), series: .value("Line", "Put in"))
                            .foregroundStyle(theme.muted).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Format.compact(d)) } } } }
                .frame(height: 200)
                Text("Solid line: what it was worth. Dashed: what you put in. Notice the dips: those are the times most people are tempted to sell.")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
        } else if loading {
            ProgressView("Loading S&P 500 history…").frame(maxWidth: .infinity, minHeight: 160)
        } else {
            Text("Price history isn't available right now. Check your connection.").foregroundStyle(theme.muted)
        }
    }
}
