import Foundation

nonisolated enum ChartStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case candles = "Candles", hollow = "Hollow candles", heikinAshi = "Heikin-Ashi", bars = "OHLC bars", line = "Line", area = "Area"
    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .candles, .hollow, .heikinAshi: return "chart.bar.xaxis"
        case .bars: return "chart.bar.doc.horizontal"
        case .line: return "chart.xyaxis.line"
        case .area: return "chart.line.uptrend.xyaxis"
        }
    }
}

nonisolated struct ChartPreferences: Codable, Hashable, Sendable {
    var style: ChartStyle = .candles
    var timeframe: Timeframe = .m5
    var indicators: [IndicatorConfig] = [
        IndicatorConfig(kind: .vwap, colorIndex: 0),
        IndicatorConfig(kind: .ema, length: 9, colorIndex: 1),
        IndicatorConfig(kind: .ema, length: 20, colorIndex: 2),
    ]
    var showVolume = true
    var showExtendedHours = true
    var showOrders = true
    var showExecutions = true
    var magnet = true

    init() {}
    private enum CodingKeys: String, CodingKey { case style, timeframe, indicators, showVolume, showExtendedHours, showOrders, showExecutions, magnet }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChartPreferences()
        style = (try? c.decodeIfPresent(ChartStyle.self, forKey: .style)) ?? d.style
        timeframe = (try? c.decodeIfPresent(Timeframe.self, forKey: .timeframe)) ?? d.timeframe
        indicators = (try? c.decodeIfPresent([IndicatorConfig].self, forKey: .indicators)) ?? d.indicators
        showVolume = (try? c.decodeIfPresent(Bool.self, forKey: .showVolume)) ?? true
        showExtendedHours = (try? c.decodeIfPresent(Bool.self, forKey: .showExtendedHours)) ?? true
        showOrders = (try? c.decodeIfPresent(Bool.self, forKey: .showOrders)) ?? true
        showExecutions = (try? c.decodeIfPresent(Bool.self, forKey: .showExecutions)) ?? true
        magnet = (try? c.decodeIfPresent(Bool.self, forKey: .magnet)) ?? true
    }
}

nonisolated struct ChartPoint: Codable, Hashable, Sendable {
    var time: Date
    var price: Double
}

nonisolated enum DrawingKind: Codable, Hashable, Sendable {
    case horizontal(price: Double)
    case trend(ChartPoint, ChartPoint)
    case ray(ChartPoint, ChartPoint)
    case rectangle(ChartPoint, ChartPoint)
    /// Fibonacci retracement between a swing low/high.
    case fibonacci(ChartPoint, ChartPoint)

    var title: String {
        switch self {
        case .horizontal: return "Horizontal line"
        case .trend: return "Trend line"
        case .ray: return "Ray"
        case .rectangle: return "Rectangle"
        case .fibonacci: return "Fib retracement"
        }
    }
    static let fibLevels: [Double] = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]
}

nonisolated enum DrawingTool: String, CaseIterable, Sendable, Identifiable {
    case horizontal = "Horizontal line", trend = "Trend line", ray = "Ray", rectangle = "Rectangle", fibonacci = "Fib retracement", measure = "Measure"
    var id: String { rawValue }
    var needsTwoPoints: Bool { self != .horizontal }
    var symbolName: String {
        switch self {
        case .horizontal: return "minus"
        case .trend: return "line.diagonal"
        case .ray: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .fibonacci: return "align.vertical.bottom"
        case .measure: return "ruler"
        }
    }
}

nonisolated struct ChartDrawing: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var symbol: String
    var kind: DrawingKind
    var colorIndex = 0
    var createdAt = Date()
}

nonisolated struct BarReplayRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var symbol: String
    var day: Date
    var timeframe: Timeframe
    var netPnL: Decimal
    var trades: Int
    var winRate: Double?
    var completedAt = Date()
}

/// A measured span on the chart: change, percent and bar count between two points.
nonisolated struct ChartMeasurement: Equatable, Sendable {
    let start: ChartPoint
    let end: ChartPoint
    let bars: Int
    var change: Double { end.price - start.price }
    var percent: Double { start.price != 0 ? change / start.price * 100 : 0 }
}
