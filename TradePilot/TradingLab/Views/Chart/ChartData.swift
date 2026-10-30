import SwiftUI

/// Everything the chart draws, computed once per data change (not per gesture frame).
struct ChartData {
    let bars: [Bar]
    let timeframe: Timeframe
    let overlays: [IndicatorSeries]
    let panes: [IndicatorSeries]
    let previousClose: Double?
    let hours: MarketHours

    static func build(bars raw: [Bar], timeframe: Timeframe, preferences: ChartPreferences, previousClose: Double?,
                      hours: MarketHours = .nyse) -> ChartData {
        var source = raw
        if timeframe.isIntraday && !preferences.showExtendedHours { source = source.filter { hours.isRegularSessionPrint($0.time) } }
        // Indicators use the real bars; Heikin-Ashi only changes the candles drawn.
        let display = preferences.style == .heikinAshi ? BarAggregator.heikinAshi(source) : source
        let configs = preferences.indicators.filter { timeframe.isIntraday || $0.kind != .vwap }
        let series = configs.map { IndicatorSeries.compute($0, bars: source, hours: hours) }
        return ChartData(bars: display, timeframe: timeframe, overlays: series.filter { $0.config.kind.isOverlay },
                         panes: series.filter { !$0.config.kind.isOverlay }, previousClose: previousClose, hours: hours)
    }
}

struct ChartOrderLine: Identifiable, Equatable {
    enum Kind { case entry, stop, target }
    let id: UUID
    let price: Double
    let label: String
    let kind: Kind
    let side: OrderSide
    let draggable: Bool
}

struct ChartExecution: Equatable {
    let time: Date
    let price: Double
    let side: OrderSide
}

struct ChartPositionLine: Equatable {
    let price: Double
    let label: String
    let isProfit: Bool
}

enum ChartPalette {
    static let colors: [Color] = [
        Color(red: 0.98, green: 0.62, blue: 0.10), Color(red: 0.20, green: 0.55, blue: 0.98), Color(red: 0.68, green: 0.40, blue: 0.95),
        Color(red: 0.10, green: 0.72, blue: 0.68), Color(red: 0.95, green: 0.35, blue: 0.60), Color(red: 0.55, green: 0.65, blue: 0.20),
    ]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
