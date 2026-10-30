import Foundation

/// Technical indicators over bar series. Every output is aligned with the input: index i is the
/// value at bar i, nil until enough bars exist. Formulas follow the common (TradingView) definitions.
nonisolated enum Indicators {
    static func sma(_ values: [Double], _ length: Int) -> [Double?] {
        guard length > 0 else { return values.map { _ in nil } }
        var result = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= length { sum -= values[i - length] }
            if i >= length - 1 { result[i] = sum / Double(length) }
        }
        return result
    }

    /// Exponential moving average seeded with the SMA of the first `length` values.
    static func ema(_ values: [Double], _ length: Int) -> [Double?] {
        guard length > 0, values.count >= length else { return values.map { _ in nil } }
        var result = [Double?](repeating: nil, count: values.count)
        let k = 2.0 / Double(length + 1)
        var current = values[0..<length].reduce(0, +) / Double(length)
        result[length - 1] = current
        for i in length..<values.count {
            current = values[i] * k + current * (1 - k)
            result[i] = current
        }
        return result
    }

    /// Wilder's smoothing (RMA), used by RSI and ATR.
    static func rma(_ values: [Double], _ length: Int) -> [Double?] {
        guard length > 0, values.count >= length else { return values.map { _ in nil } }
        var result = [Double?](repeating: nil, count: values.count)
        var current = values[0..<length].reduce(0, +) / Double(length)
        result[length - 1] = current
        for i in length..<values.count {
            current = (current * Double(length - 1) + values[i]) / Double(length)
            result[i] = current
        }
        return result
    }

    static func rsi(_ closes: [Double], _ length: Int = 14) -> [Double?] {
        guard closes.count > length else { return closes.map { _ in nil } }
        var gains = [Double](), losses = [Double]()
        for i in 1..<closes.count {
            let change = closes[i] - closes[i - 1]
            gains.append(max(change, 0))
            losses.append(max(-change, 0))
        }
        let avgGain = rma(gains, length), avgLoss = rma(losses, length)
        var result: [Double?] = [nil]
        for i in gains.indices {
            guard let g = avgGain[i], let l = avgLoss[i] else { result.append(nil); continue }
            result.append(l == 0 ? (g == 0 ? 50 : 100) : 100 - 100 / (1 + g / l))
        }
        return result
    }

    struct MACD: Sendable { let macd: [Double?]; let signal: [Double?]; let histogram: [Double?] }

    static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> MACD {
        let f = ema(closes, fast), s = ema(closes, slow)
        let line: [Double?] = closes.indices.map { i in
            guard let a = f[i], let b = s[i] else { return nil }
            return a - b
        }
        // Signal = EMA of the MACD line over the bars where it exists.
        let start = line.firstIndex { $0 != nil } ?? line.count
        let defined = line[start...].compactMap { $0 }
        let signalDefined = ema(defined, signal)
        var signalLine = [Double?](repeating: nil, count: closes.count)
        for (offset, value) in signalDefined.enumerated() { signalLine[start + offset] = value }
        let histogram: [Double?] = closes.indices.map { i in
            guard let m = line[i], let sg = signalLine[i] else { return nil }
            return m - sg
        }
        return MACD(macd: line, signal: signalLine, histogram: histogram)
    }

    struct Bands: Sendable { let middle: [Double?]; let upper: [Double?]; let lower: [Double?] }

    /// Bollinger Bands with population standard deviation.
    static func bollinger(_ closes: [Double], length: Int = 20, multiplier: Double = 2) -> Bands {
        let middle = sma(closes, length)
        var upper = [Double?](repeating: nil, count: closes.count), lower = upper
        for i in closes.indices {
            guard let mean = middle[i] else { continue }
            let window = closes[(i - length + 1)...i]
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(length)
            let deviation = variance.squareRoot() * multiplier
            upper[i] = mean + deviation
            lower[i] = mean - deviation
        }
        return Bands(middle: middle, upper: upper, lower: lower)
    }

    static func trueRange(_ bars: [Bar]) -> [Double] {
        bars.indices.map { i in
            let bar = bars[i]
            guard i > 0 else { return bar.high - bar.low }
            let previous = bars[i - 1].close
            return max(bar.high - bar.low, abs(bar.high - previous), abs(bar.low - previous))
        }
    }

    static func atr(_ bars: [Bar], _ length: Int = 14) -> [Double?] { rma(trueRange(bars), length) }

    /// Session VWAP: resets at the start of each ET trading day. Uses the typical price.
    static func vwap(_ bars: [Bar], hours: MarketHours = .nyse) -> [Double?] {
        var result = [Double?](repeating: nil, count: bars.count)
        var day: Date?
        var priceVolume = 0.0, volume = 0.0
        for (i, bar) in bars.enumerated() {
            let barDay = hours.dayStart(bar.time)
            if barDay != day { day = barDay; priceVolume = 0; volume = 0 }
            priceVolume += bar.typical * bar.volume
            volume += bar.volume
            result[i] = volume > 0 ? priceVolume / volume : bar.typical
        }
        return result
    }

    /// Stochastic %K (smoothed) and %D.
    static func stochastic(_ bars: [Bar], length: Int = 14, smoothK: Int = 3, smoothD: Int = 3) -> (k: [Double?], d: [Double?]) {
        var raw = [Double?](repeating: nil, count: bars.count)
        for i in bars.indices where i >= length - 1 {
            let window = bars[(i - length + 1)...i]
            let high = window.map(\.high).max()!, low = window.map(\.low).min()!
            raw[i] = high == low ? 50 : (bars[i].close - low) / (high - low) * 100
        }
        let k = smoothDefined(raw, smoothK)
        return (k, smoothDefined(k, smoothD))
    }

    private static func smoothDefined(_ values: [Double?], _ length: Int) -> [Double?] {
        let start = values.firstIndex { $0 != nil } ?? values.count
        let defined = values[start...].compactMap { $0 }
        var result = [Double?](repeating: nil, count: values.count)
        for (offset, value) in sma(defined, length).enumerated() { result[start + offset] = value }
        return result
    }

    /// Today's cumulative volume divided by the average cumulative volume at the same time of day
    /// over previous sessions in the series (intraday bars). Nil without enough history.
    static func relativeVolume(_ bars: [Bar], at index: Int? = nil, hours: MarketHours = .nyse) -> Double? {
        guard !bars.isEmpty else { return nil }
        let i = index ?? bars.count - 1
        let reference = bars[i].time
        let today = hours.dayStart(reference)
        let secondsIntoDay = reference.timeIntervalSince(today)
        var cumulative: [Date: Double] = [:]
        for bar in bars[...i] {
            let day = hours.dayStart(bar.time)
            guard bar.time.timeIntervalSince(day) <= secondsIntoDay else { continue }
            cumulative[day, default: 0] += bar.volume
        }
        guard let todayVolume = cumulative.removeValue(forKey: today), !cumulative.isEmpty else { return nil }
        let average = cumulative.values.reduce(0, +) / Double(cumulative.count)
        return average > 0 ? todayVolume / average : nil
    }
}

// MARK: - Chart indicator configuration

nonisolated enum IndicatorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case sma = "SMA", ema = "EMA", vwap = "VWAP", bollinger = "Bollinger Bands"
    case rsi = "RSI", macd = "MACD", atr = "ATR", stochastic = "Stochastic"
    var id: String { rawValue }
    var isOverlay: Bool { self == .sma || self == .ema || self == .vwap || self == .bollinger }
    var defaultLength: Int {
        switch self {
        case .sma: return 50
        case .ema: return 9
        case .vwap: return 0
        case .bollinger: return 20
        case .rsi, .atr, .stochastic: return 14
        case .macd: return 12
        }
    }
    var explanation: String {
        switch self {
        case .sma: return "Simple moving average: the mean close over the last N bars."
        case .ema: return "Exponential moving average: weights recent closes more, so it turns sooner than an SMA."
        case .vwap: return "Volume-weighted average price for the session. Many intraday traders treat it as fair value for the day."
        case .bollinger: return "A moving average with bands two standard deviations away. Wide bands mean high volatility."
        case .rsi: return "Relative Strength Index (0–100) measures the speed of recent moves. 70+ is often called overbought, 30− oversold."
        case .macd: return "Difference between a fast and slow EMA, with a signal line. Crossovers mark momentum shifts."
        case .atr: return "Average True Range: the typical bar range. Useful for sizing stops to current volatility."
        case .stochastic: return "Where the close sits inside the recent high–low range (0–100)."
        }
    }
}

nonisolated struct IndicatorConfig: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString
    var kind: IndicatorKind
    var length: Int
    var colorIndex: Int

    init(kind: IndicatorKind, length: Int? = nil, colorIndex: Int = 0) {
        self.kind = kind
        self.length = length ?? kind.defaultLength
        self.colorIndex = colorIndex
    }

    var title: String { kind == .vwap ? "VWAP" : kind == .macd ? "MACD 12 26 9" : "\(kind.rawValue) \(length)" }
}

/// Computed lines for one indicator, aligned with the bars.
nonisolated struct IndicatorSeries: Sendable {
    struct Line: Sendable { let name: String; let values: [Double?]; let role: Int }
    let config: IndicatorConfig
    let lines: [Line]
    let histogram: [Double?]?
    /// Reference levels drawn as dashed lines (e.g. RSI 30/70).
    let levels: [Double]
    /// Fixed y-range for oscillators.
    let range: ClosedRange<Double>?

    static func compute(_ config: IndicatorConfig, bars: [Bar], hours: MarketHours = .nyse) -> IndicatorSeries {
        let closes = bars.map(\.close)
        let n = max(1, config.length)
        switch config.kind {
        case .sma: return .init(config: config, lines: [.init(name: "SMA", values: Indicators.sma(closes, n), role: 0)], histogram: nil, levels: [], range: nil)
        case .ema: return .init(config: config, lines: [.init(name: "EMA", values: Indicators.ema(closes, n), role: 0)], histogram: nil, levels: [], range: nil)
        case .vwap: return .init(config: config, lines: [.init(name: "VWAP", values: Indicators.vwap(bars, hours: hours), role: 0)], histogram: nil, levels: [], range: nil)
        case .bollinger:
            let b = Indicators.bollinger(closes, length: n)
            return .init(config: config, lines: [.init(name: "Upper", values: b.upper, role: 1), .init(name: "Basis", values: b.middle, role: 0),
                                                 .init(name: "Lower", values: b.lower, role: 1)], histogram: nil, levels: [], range: nil)
        case .rsi: return .init(config: config, lines: [.init(name: "RSI", values: Indicators.rsi(closes, n), role: 0)], histogram: nil, levels: [30, 70], range: 0...100)
        case .atr: return .init(config: config, lines: [.init(name: "ATR", values: Indicators.atr(bars, n), role: 0)], histogram: nil, levels: [], range: nil)
        case .macd:
            let m = Indicators.macd(closes)
            return .init(config: config, lines: [.init(name: "MACD", values: m.macd, role: 0), .init(name: "Signal", values: m.signal, role: 2)],
                         histogram: m.histogram, levels: [0], range: nil)
        case .stochastic:
            let s = Indicators.stochastic(bars, length: n)
            return .init(config: config, lines: [.init(name: "%K", values: s.k, role: 0), .init(name: "%D", values: s.d, role: 2)],
                         histogram: nil, levels: [20, 80], range: 0...100)
        }
    }

    /// Min/max over a visible index range, for autoscaling.
    func extent(in range: ClosedRange<Int>) -> (Double, Double)? {
        var low = Double.infinity, high = -Double.infinity
        for line in lines { for i in range where i < line.values.count { if let v = line.values[i] { low = min(low, v); high = max(high, v) } } }
        if let histogram { for i in range where i < histogram.count { if let v = histogram[i] { low = min(low, v); high = max(high, v) } } }
        return low.isFinite ? (low, high) : nil
    }
}
