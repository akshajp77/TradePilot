import Foundation

/// Which bars are on screen. Indices are fractional so pinch and pan are smooth.
nonisolated struct ChartViewport: Equatable, Sendable {
    static let minimumBars: Double = 12
    /// Empty space allowed to the right of the last bar, in bars.
    static let rightPadding: Double = 8

    var barCount: Int
    /// How many bars span the plot width.
    var visibleBars: Double
    /// Fractional bar index at the right edge of the plot.
    var rightEdge: Double

    static func initial(barCount: Int, visible: Double = 90) -> ChartViewport {
        var viewport = ChartViewport(barCount: barCount, visibleBars: visible, rightEdge: Double(barCount) + 3)
        viewport.clamp()
        return viewport
    }

    var leftEdge: Double { rightEdge - visibleBars }
    var isAtLatest: Bool { rightEdge >= Double(barCount) - 0.5 }

    /// Bar indices at least partly visible.
    var visibleRange: ClosedRange<Int>? {
        guard barCount > 0 else { return nil }
        let lower = max(0, Int(leftEdge.rounded(.down)))
        let upper = min(barCount - 1, Int(rightEdge.rounded(.up)))
        return lower <= upper ? lower...upper : nil
    }

    func barWidth(plotWidth: Double) -> Double { plotWidth / visibleBars }

    /// Center x of bar `index`.
    func x(for index: Double, plotWidth: Double) -> Double {
        (index - leftEdge + 0.5) * barWidth(plotWidth: plotWidth)
    }

    func index(atX x: Double, plotWidth: Double) -> Double {
        x / barWidth(plotWidth: plotWidth) + leftEdge - 0.5
    }

    mutating func pan(byPoints dx: Double, plotWidth: Double) {
        rightEdge -= dx / barWidth(plotWidth: plotWidth)
        clamp()
    }

    /// factor > 1 zooms in. `anchor` is the x position (0…1 of plot width) that stays fixed.
    mutating func zoom(by factor: Double, anchor: Double) {
        guard factor > 0 else { return }
        let anchorIndex = leftEdge + visibleBars * anchor
        visibleBars = visibleBars / factor
        clampZoom()
        rightEdge = anchorIndex + visibleBars * (1 - anchor)
        clamp()
    }

    mutating func scrollToLatest() {
        rightEdge = Double(barCount) + 3
        clamp()
    }

    /// Keeps the viewport valid when bars are appended; follows the live edge if it was there.
    mutating func update(barCount newCount: Int) {
        let following = isAtLatest
        let added = newCount - barCount
        barCount = newCount
        if following && added > 0 { rightEdge += Double(added) }
        clamp()
    }

    private mutating func clampZoom() {
        let maximum = max(ChartViewport.minimumBars, Double(barCount) + ChartViewport.rightPadding)
        visibleBars = min(max(visibleBars, ChartViewport.minimumBars), maximum)
    }

    mutating func clamp() {
        clampZoom()
        let maxRight = Double(barCount) + ChartViewport.rightPadding
        let minRight = min(maxRight, visibleBars * 0.25) // keep a sliver of data on screen when scrolled far left
        rightEdge = min(max(rightEdge, minRight), maxRight)
    }
}

/// Maps prices to y coordinates (y grows downward).
nonisolated struct PriceScale: Equatable, Sendable {
    var low: Double
    var high: Double

    init(low: Double, high: Double, padding: Double = 0.08) {
        var lo = low, hi = high
        if !lo.isFinite || !hi.isFinite { lo = 0; hi = 1 }
        if hi - lo < max(abs(hi) * 0.0005, 0.0001) { let mid = (hi + lo) / 2; lo = mid - max(abs(mid) * 0.001, 0.01); hi = mid + max(abs(mid) * 0.001, 0.01) }
        let pad = (hi - lo) * padding
        self.low = lo - pad
        self.high = hi + pad
    }

    /// Autoscale over visible bars plus any extra values that must stay on screen (overlays, order lines).
    static func fit(bars: [Bar], range: ClosedRange<Int>, include extra: [Double] = [], padding: Double = 0.08) -> PriceScale {
        var lo = Double.infinity, hi = -Double.infinity
        for i in range where i < bars.count { lo = min(lo, bars[i].low); hi = max(hi, bars[i].high) }
        for value in extra where value.isFinite { lo = min(lo, value); hi = max(hi, value) }
        return PriceScale(low: lo, high: hi, padding: padding)
    }

    func y(_ price: Double, height: Double) -> Double {
        guard high > low else { return height / 2 }
        return (high - price) / (high - low) * height
    }

    func price(atY y: Double, height: Double) -> Double {
        guard height > 0 else { return low }
        return high - y / height * (high - low)
    }

    func ticks(maxCount: Int = 6) -> [Double] { NiceTicks.values(low: low, high: high, maxCount: maxCount) }
}

nonisolated enum NiceTicks {
    /// Round tick values ("nice numbers": 1, 2, 2.5, 5 × 10ⁿ) inside [low, high].
    static func values(low: Double, high: Double, maxCount: Int) -> [Double] {
        guard high > low, maxCount > 0, low.isFinite, high.isFinite else { return [] }
        let step = niceStep((high - low) / Double(maxCount))
        guard step > 0 else { return [] }
        var tick = (low / step).rounded(.up) * step
        var result: [Double] = []
        while tick <= high + step * 1e-9 && result.count < maxCount * 2 {
            result.append(abs(tick) < step * 1e-9 ? 0 : tick)
            tick += step
        }
        return result
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 0 }
        let exponent = pow(10, (log10(raw)).rounded(.down))
        let fraction = raw / exponent
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
        return nice * exponent
    }

    /// Bar indices to label on the time axis: evenly spaced by an absolute step so labels
    /// do not jitter while panning, preferring session starts on intraday charts.
    static func timeIndices(bars: [Bar], visible: ClosedRange<Int>, maxLabels: Int, hours: MarketHours = .nyse) -> [Int] {
        guard maxLabels > 0, !bars.isEmpty else { return [] }
        let span = visible.count
        let step = max(1, Int((Double(span) / Double(maxLabels)).rounded(.up)))
        var result: [Int] = []
        for i in visible where i % step == 0 && i < bars.count { result.append(i) }
        return result
    }
}

/// Converts between chart coordinates and the time/price a drawing is anchored to,
/// so drawings stay put when the timeframe changes.
nonisolated enum ChartAnchoring {
    /// Fractional bar index for a time, interpolating between bars and extrapolating past the ends.
    static func index(for time: Date, in bars: [Bar], timeframe: Timeframe) -> Double? {
        guard let first = bars.first, let last = bars.last else { return nil }
        if time <= first.time { return -(first.time.timeIntervalSince(time) / timeframe.seconds) }
        if time >= last.time { return Double(bars.count - 1) + time.timeIntervalSince(last.time) / timeframe.seconds }
        var lo = 0, hi = bars.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if bars[mid].time <= time { lo = mid } else { hi = mid }
        }
        let span = bars[hi].time.timeIntervalSince(bars[lo].time)
        return Double(lo) + (span > 0 ? time.timeIntervalSince(bars[lo].time) / span : 0)
    }

    static func time(for index: Double, in bars: [Bar], timeframe: Timeframe) -> Date? {
        guard let first = bars.first, let last = bars.last else { return nil }
        if index <= 0 { return first.time.addingTimeInterval(index * timeframe.seconds) }
        if index >= Double(bars.count - 1) { return last.time.addingTimeInterval((index - Double(bars.count - 1)) * timeframe.seconds) }
        let lo = Int(index.rounded(.down)), hi = lo + 1
        let fraction = index - Double(lo)
        return bars[lo].time.addingTimeInterval(bars[hi].time.timeIntervalSince(bars[lo].time) * fraction)
    }
}
