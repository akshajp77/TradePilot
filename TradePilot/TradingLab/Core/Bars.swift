import Foundation

nonisolated struct Bar: Codable, Hashable, Sendable {
    var time: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double

    var typical: Double { (high + low + close) / 3 }
    var isUp: Bool { close >= open }
    var range: Double { high - low }
}

nonisolated enum Timeframe: String, CaseIterable, Codable, Identifiable, Sendable {
    case m1 = "1m", m5 = "5m", m15 = "15m", h1 = "1h", d1 = "1D", w1 = "1W"
    var id: String { rawValue }

    var isIntraday: Bool { self != .d1 && self != .w1 }

    /// Bar length for intraday timeframes.
    var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m5: return 300
        case .m15: return 900
        case .h1: return 3600
        case .d1: return 86_400
        case .w1: return 7 * 86_400
        }
    }

    /// Yahoo chart request with the longest history it serves for that interval.
    var yahoo: (interval: String, range: String) {
        switch self {
        case .m1: return ("1m", "5d")
        case .m5: return ("5m", "1mo")
        case .m15: return ("15m", "1mo")
        case .h1: return ("60m", "6mo")
        case .d1: return ("1d", "2y")
        case .w1: return ("1wk", "10y")
        }
    }

    var label: String {
        switch self {
        case .m1: return "1 minute"
        case .m5: return "5 minutes"
        case .m15: return "15 minutes"
        case .h1: return "1 hour"
        case .d1: return "1 day"
        case .w1: return "1 week"
        }
    }

    /// Start of the bar containing `date`. Intraday buckets align to the 9:30 ET open so hourly
    /// bars read 9:30, 10:30… like the exchange data; daily and weekly bars start at the session open.
    func bucketStart(for date: Date, hours: MarketHours = .nyse) -> Date {
        let calendar = hours.calendar
        let dayStart = calendar.startOfDay(for: date)
        let open = dayStart.addingTimeInterval(9.5 * 3600)
        switch self {
        case .m1, .m5, .m15:
            let offset = date.timeIntervalSince(dayStart)
            return dayStart.addingTimeInterval((offset / seconds).rounded(.down) * seconds)
        case .h1:
            let offset = date.timeIntervalSince(open)
            return open.addingTimeInterval((offset / seconds).rounded(.down) * seconds)
        case .d1:
            return open
        case .w1:
            let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
            let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: dayStart) ?? dayStart
            return monday.addingTimeInterval(9.5 * 3600)
        }
    }
}

nonisolated enum BarAggregator {
    /// Folds a trade print into the bar series. Returns true when a new bar was started.
    @discardableResult
    static func apply(price: Double, size: Double, time: Date, to bars: inout [Bar], timeframe: Timeframe,
                      hours: MarketHours = .nyse, includeExtended: Bool = true) -> Bool {
        guard price > 0 else { return false }
        if !includeExtended || !timeframe.isIntraday {
            // Daily and weekly bars, and regular-only charts, take regular-session prints only.
            guard hours.isRegularSessionPrint(time) else { return false }
        } else {
            guard hours.sessionKind(at: time) != .closed else { return false }
        }
        let bucket = timeframe.bucketStart(for: time, hours: hours)
        if let last = bars.last {
            if bucket == last.time {
                var bar = last
                bar.high = max(bar.high, price)
                bar.low = min(bar.low, price)
                bar.close = price
                bar.volume += size
                bars[bars.count - 1] = bar
                return false
            }
            if bucket < last.time { return false } // late print for an older bar: ignore
        }
        bars.append(Bar(time: bucket, open: price, high: price, low: price, close: price, volume: size))
        return true
    }

    /// Builds higher-timeframe bars from lower ones (e.g. 1m → 5m for replay).
    static func resample(_ bars: [Bar], to timeframe: Timeframe, hours: MarketHours = .nyse) -> [Bar] {
        var result: [Bar] = []
        for bar in bars {
            let bucket = timeframe.bucketStart(for: bar.time, hours: hours)
            if var last = result.last, last.time == bucket {
                last.high = max(last.high, bar.high)
                last.low = min(last.low, bar.low)
                last.close = bar.close
                last.volume += bar.volume
                result[result.count - 1] = last
            } else {
                result.append(Bar(time: bucket, open: bar.open, high: bar.high, low: bar.low, close: bar.close, volume: bar.volume))
            }
        }
        return result
    }

    /// Heikin-Ashi transform for the chart.
    static func heikinAshi(_ bars: [Bar]) -> [Bar] {
        var result: [Bar] = []
        result.reserveCapacity(bars.count)
        for (i, bar) in bars.enumerated() {
            let close = (bar.open + bar.high + bar.low + bar.close) / 4
            let open = i == 0 ? (bar.open + bar.close) / 2 : (result[i - 1].open + result[i - 1].close) / 2
            result.append(Bar(time: bar.time, open: open, high: max(bar.high, open, close), low: min(bar.low, open, close), close: close, volume: bar.volume))
        }
        return result
    }
}
