import Foundation

/// Small, seedable random generator so simulations are repeatable in tests.
nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Expectancy and position-size lab

nonisolated struct SizingSimulation: Sendable, Equatable {
    struct Inputs: Sendable, Equatable {
        var winRate = 0.45
        /// Average win in multiples of the amount risked (2 = winners make twice what losers lose).
        var winR = 2.0
        var lossR = 1.0
        var riskFraction = 0.01
        var trades = 200
        var paths = 1000
        var startingBalance = 10_000.0
        /// A drop this big from the start counts as "blown up".
        var ruinDrawdown = 0.5
    }
    let inputs: Inputs
    /// Average result per trade in R: winRate × winR − (1 − winRate) × lossR.
    let expectancyR: Double
    let medianEnding: Double
    let worstTenth: Double
    let bestTenth: Double
    let ruinProbability: Double
    let medianMaxDrawdown: Double
    /// Equity after each trade for a few sample paths, for the chart.
    let samplePaths: [[Double]]

    static func run(_ i: Inputs, seed: UInt64 = 42) -> SizingSimulation {
        var rng = SplitMix64(seed: seed)
        var endings: [Double] = []
        var drawdowns: [Double] = []
        var ruined = 0
        var samples: [[Double]] = []
        for p in 0..<max(1, i.paths) {
            var equity = i.startingBalance
            var peak = equity
            var worstDrawdown = 0.0
            var hitRuin = false
            var path: [Double] = p < 5 ? [equity] : []
            for _ in 0..<max(1, i.trades) {
                let win = Double.random(in: 0..<1, using: &rng) < i.winRate
                let r = win ? i.winR : -i.lossR
                equity = max(0, equity * (1 + i.riskFraction * r))
                peak = max(peak, equity)
                worstDrawdown = max(worstDrawdown, peak > 0 ? 1 - equity / peak : 1)
                if equity <= i.startingBalance * (1 - i.ruinDrawdown) { hitRuin = true }
                if p < 5 { path.append(equity) }
            }
            if hitRuin { ruined += 1 }
            endings.append(equity)
            drawdowns.append(worstDrawdown)
            if p < 5 { samples.append(path) }
        }
        endings.sort(); drawdowns.sort()
        func pct(_ values: [Double], _ q: Double) -> Double { values[min(values.count - 1, Int(Double(values.count - 1) * q))] }
        return SizingSimulation(inputs: i, expectancyR: i.winRate * i.winR - (1 - i.winRate) * i.lossR,
                                medianEnding: pct(endings, 0.5), worstTenth: pct(endings, 0.1), bestTenth: pct(endings, 0.9),
                                ruinProbability: Double(ruined) / Double(endings.count), medianMaxDrawdown: pct(drawdowns, 0.5),
                                samplePaths: samples)
    }

    /// Losing streak length that has about a 50% chance of showing up somewhere in `trades` trades.
    static func typicalLosingStreak(winRate: Double, trades: Int) -> Int {
        let q = 1 - winRate
        guard q > 0, q < 1 else { return q >= 1 ? trades : 0 }
        return max(1, Int((log(Double(trades) * (1 - q)) / -log(q)).rounded()))
    }
}

// MARK: - Investing vs trading

nonisolated enum InvestingMath {
    struct Result: Sendable, Equatable {
        let contributed: Double
        let value: Double
        let series: [(date: Date, contributed: Double, value: Double)]
        static func == (a: Result, b: Result) -> Bool { a.contributed == b.contributed && a.value == b.value }
    }

    /// Buys a fixed dollar amount at each price (monthly closes). Fractional shares, no fees, dividends ignored.
    static func dollarCostAverage(prices: [(date: Date, close: Double)], monthly: Double, initial: Double = 0) -> Result {
        var shares = 0.0, contributed = 0.0
        var series: [(Date, Double, Double)] = []
        for (index, point) in prices.enumerated() where point.close > 0 {
            let amount = monthly + (index == 0 ? initial : 0)
            shares += amount / point.close
            contributed += amount
            series.append((point.date, contributed, shares * point.close))
        }
        return Result(contributed: contributed, value: series.last?.2 ?? 0, series: series)
    }

    /// Monthly closes from daily or weekly bars: the last bar of each calendar month.
    static func monthlyCloses(_ bars: [Bar], calendar: Calendar = .current) -> [(date: Date, close: Double)] {
        var result: [(Date, Double)] = []
        var lastKey: DateComponents?
        for bar in bars {
            let key = calendar.dateComponents([.year, .month], from: bar.time)
            if key == lastKey, !result.isEmpty { result[result.count - 1] = (bar.time, bar.close) }
            else { result.append((bar.time, bar.close)); lastKey = key }
        }
        return result
    }

    /// Future value with a fixed annual return, compounded monthly.
    static func compound(initial: Double, monthly: Double, annualReturn: Double, years: Int) -> (contributed: Double, value: Double) {
        let r = annualReturn / 12
        var value = initial, contributed = initial
        for _ in 0..<(years * 12) { value = value * (1 + r) + monthly; contributed += monthly }
        return (contributed, value)
    }

    /// What frequent trading costs before any wins or losses: spread and slippage on both sides, plus commissions.
    static func tradingCosts(tradesPerDay: Double, positionSize: Double, spreadBps: Double, slippageBps: Double,
                             commissionPerTrade: Double, days: Int = 252) -> Double {
        let perRoundTrip = positionSize * (spreadBps + 2 * slippageBps) / 10_000 + 2 * commissionPerTrade
        return perRoundTrip * tradesPerDay * Double(days)
    }
}
