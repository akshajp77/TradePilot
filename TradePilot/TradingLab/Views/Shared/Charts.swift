import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct ChartRangePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selection: ChartRange
    var body: some View {
        GeometryReader { geometry in
            let width = max(32, (geometry.size.width - 4 * CGFloat(ChartRange.allCases.count - 1)) / CGFloat(ChartRange.allCases.count))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s4) {
                    ForEach(ChartRange.allCases) { range in
                        Button { selection = range } label: {
                            Text(range.rawValue).font(theme.meta.weight(selection == range ? .semibold : .regular))
                                .foregroundStyle(selection == range ? theme.ink : theme.muted)
                                .lineLimit(1).minimumScaleFactor(0.8).frame(width: width, height: 36)
                                .background(selection == range ? theme.line.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(selection == range ? .isSelected : [])
                    }
                }
            }
        }.frame(height: 40).accessibilityLabel("Chart time range")
    }
}

#if os(iOS)
final class ChartTouchView: UIView {
    var changed: ([CGFloat]) -> Void = { _ in }
    private var active = Set<UITouch>()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func report() {
        guard bounds.width > 0 else { return }
        changed(active.map { min(max($0.location(in: self).x / bounds.width, 0), 1) }.sorted())
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { active.formUnion(touches); report() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { active.subtract(touches); report() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { active.subtract(touches); report() }
}

struct ChartTouchSurface: UIViewRepresentable {
    let changed: ([CGFloat]) -> Void
    func makeUIView(context: Context) -> ChartTouchView { ChartTouchView(frame: .zero) }
    func updateUIView(_ view: ChartTouchView, context: Context) { view.changed = changed }
}
#endif

struct ChartInspection: Equatable {
    let startPrice: Double
    let endPrice: Double
    let startDate: Date?
    let endDate: Date
    var dollars: Double { endPrice - startPrice }
    var percent: Double { startPrice > 0 ? (endPrice / startPrice - 1) * 100 : 0 }
}

struct InteractiveLineChart: View {
    @Environment(\.theme) private var theme
    let points: [PricePoint]
    let baseline: Double?
    let title: String
    @Binding var range: ChartRange
    var onComparisonChange: (Double?) -> Void = { _ in }
    var onInspectionChange: (ChartInspection?) -> Void = { _ in }
    var stockStyle = false
    var chartHeight: CGFloat = 190
    @State private var selected: PricePoint?
    @State private var comparison: (PricePoint, PricePoint)?
    @State private var comparisonAnchor: PricePoint?

    private var lineColor: Color {
        guard let first = points.first, let last = points.last else { return theme.accent }
        let up = last.price >= (baseline ?? first.price)
        return stockStyle ? theme.movement(up) : theme.gain(up)
    }
    private var yBounds: ClosedRange<Double> {
        let values = points.map(\.price) + (baseline.map { [$0] } ?? [])
        let low = values.min() ?? 0, high = values.max() ?? 1
        let padding = max((high - low) * 0.10, max(low * 0.0015, 0.01))
        return (low - padding)...(high + padding)
    }
    private func percent(_ first: PricePoint, _ last: PricePoint) -> Double {
        first.price > 0 ? (last.price / first.price - 1) * 100 : 0
    }
    private func clearInspection() {
        withAnimation(.easeOut(duration: 0.2)) { selected = nil; comparison = nil; comparisonAnchor = nil }
        onComparisonChange(nil); onInspectionChange(nil)
    }
    private func nearest(_ date: Date) -> PricePoint? {
        // Points are time-ordered: binary search instead of a linear scan per drag event.
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(points[low - 1].date.timeIntervalSince(date)) < abs(points[low].date.timeIntervalSince(date)) { return points[low - 1] }
        return points[low]
    }
    private func inspectionFor(_ point: PricePoint) -> ChartInspection? {
        guard let first = points.first else { return nil }
        return ChartInspection(startPrice: baseline ?? first.price, endPrice: point.price, startDate: baseline == nil ? first.date : nil, endDate: point.date)
    }
    private func select(_ positions: [CGFloat], proxy: ChartProxy, width: CGFloat) {
        guard width > 0 else { return }
        guard !positions.isEmpty else { clearInspection(); return }
        let values = positions.prefix(2).compactMap { proxy.value(atX: $0 * width, as: Date.self).flatMap(nearest) }
        if values.count == 2 {
            comparison = (values[0], values[1]); selected = nil
            onComparisonChange(percent(values[0], values[1]))
            onInspectionChange(ChartInspection(startPrice: values[0].price, endPrice: values[1].price, startDate: values[0].date, endDate: values[1].date))
        } else if let point = values.first {
            selected = point; comparison = nil; comparisonAnchor = nil
            if let inspection = inspectionFor(point) { onComparisonChange(inspection.percent); onInspectionChange(inspection) }
        }
    }
    #if os(macOS)
    private func selectWithOption(_ normalized: CGFloat, proxy: ChartProxy, width: CGFloat) {
        guard let date = proxy.value(atX: normalized * width, as: Date.self), let point = nearest(date) else { return }
        if let anchor = comparisonAnchor ?? selected {
            comparisonAnchor = anchor
            let pair = anchor.date <= point.date ? (anchor, point) : (point, anchor)
            comparison = pair; selected = nil
            onComparisonChange(percent(pair.0, pair.1))
            onInspectionChange(ChartInspection(startPrice: pair.0.price, endPrice: pair.1.price, startDate: pair.0.date, endDate: pair.1.date))
        } else {
            comparisonAnchor = point; selected = point
            onInspectionChange(inspectionFor(point))
        }
    }
    #endif
    private var inspection: ChartInspection? {
        if let comparison { return ChartInspection(startPrice: comparison.0.price, endPrice: comparison.1.price, startDate: comparison.0.date, endDate: comparison.1.date) }
        return selected.flatMap(inspectionFor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Group {
                if let inspection {
                    HStack(alignment: .center, spacing: Space.s8) {
                        AnimatedMoney(value: inspection.dollars, font: theme.label, showPlus: true)
                        AnimatedPercent(value: inspection.percent, font: theme.label)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let start = inspection.startDate {
                                Text(start.formatted(date: .omitted, time: .shortened) + " → " + inspection.endDate.formatted(date: .omitted, time: .shortened))
                            } else {
                                Text((stockStyle ? "Previous close" : "Start") + " → " + inspection.endDate.formatted(date: .omitted, time: .shortened))
                            }
                            Text(inspection.endDate.formatted(date: .abbreviated, time: .omitted))
                        }.font(theme.meta).foregroundStyle(theme.muted).lineLimit(1).minimumScaleFactor(0.7)
                    }.foregroundStyle(stockStyle ? theme.movement(inspection.dollars >= 0) : theme.gain(inspection.dollars >= 0))
                } else { ChartRangePicker(selection: $range) }
            }.frame(height: 40)
            if points.isEmpty {
                Text("No recorded prices in this range yet.")
                    .font(theme.label).foregroundStyle(theme.muted).frame(maxWidth: .infinity, minHeight: 190)
            } else {
                chart.frame(height: chartHeight)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) chart")
        .onDisappear { onInspectionChange(nil); onComparisonChange(nil) }
    }

    private var chart: some View {
        Chart {
            if let baseline {
                RuleMark(y: .value(stockStyle ? "Previous close" : "Starting value", baseline))
                    .foregroundStyle(stockStyle ? lineColor.opacity(0.6) : theme.muted.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(points) { point in
                if stockStyle {
                    AreaMark(x: .value("Time", point.date), yStart: .value("Floor", yBounds.lowerBound), yEnd: .value(title, point.price))
                        .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.22), lineColor.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                }
                LineMark(x: .value("Time", point.date), y: .value(title, point.price))
                    .interpolationMethod(.linear).foregroundStyle(lineColor).lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            if points.count == 1, let only = points.first {
                PointMark(x: .value("Time", only.date), y: .value(title, only.price)).foregroundStyle(lineColor)
            }
            if let selected {
                RuleMark(x: .value("Selected time", selected.date)).foregroundStyle(theme.muted)
                PointMark(x: .value("Selected time", selected.date), y: .value("Selected value", selected.price))
                    .foregroundStyle(theme.ink)
                    .annotation(position: .top, spacing: 10) { priceTag(selected.price) }
            }
            if let comparison {
                RuleMark(x: .value("Start", comparison.0.date)).foregroundStyle(theme.muted)
                RuleMark(x: .value("End", comparison.1.date)).foregroundStyle(theme.muted)
                PointMark(x: .value("Start", comparison.0.date), y: .value("Start price", comparison.0.price))
                    .foregroundStyle(theme.ink).annotation(position: .top, spacing: 10) { priceTag(comparison.0.price) }
                PointMark(x: .value("End", comparison.1.date), y: .value("End price", comparison.1.price))
                    .foregroundStyle(theme.ink).annotation(position: .top, spacing: 10) { priceTag(comparison.1.price) }
            }
        }
        .chartXAxis {
            if stockStyle {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Group {
                                if range == .day { Text(date.formatted(.dateTime.hour())) }
                                else if range == .hour { Text(date.formatted(.dateTime.hour().minute())) }
                                else { Text(date.formatted(.dateTime.month(.abbreviated).day())) }
                            }.font(theme.meta).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
        }
        .chartYScale(domain: yBounds)
        .chartYAxis {
            AxisMarks(position: stockStyle ? .trailing : .leading) { _ in
                AxisGridLine().foregroundStyle(theme.line)
                AxisValueLabel(format: .currency(code: "USD").precision(.fractionLength(stockStyle ? 2 : 0))).font(theme.meta)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    #if os(iOS)
                    ChartTouchSurface { positions in select(positions, proxy: proxy, width: plot.width) }
                        .frame(width: plot.width, height: plot.height)
                        .position(x: plot.midX, y: plot.midY)
                    #else
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: plot.width, height: plot.height)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let position = min(max(value.location.x / plot.width, 0), 1)
                            if NSEvent.modifierFlags.contains(.option) { selectWithOption(position, proxy: proxy, width: plot.width) }
                            else { select([position], proxy: proxy, width: plot.width) }
                        }.onEnded { _ in clearInspection() })
                        .position(x: plot.midX, y: plot.midY)
                    #endif
                }
            }
        }
    }

    private func priceTag(_ price: Double) -> some View {
        Text(Format.money(price)).font(theme.meta.weight(.medium)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(theme.paper, in: RoundedRectangle(cornerRadius: Space.smallRadius))
    }
}

struct MarketSparkline: View {
    @Environment(\.theme) private var theme
    @ObservedObject var market: MarketData
    let symbol: String
    var body: some View {
        let points = market.points(symbol, range: .day)
        let baseline = market.previousClose(symbol)
        let prices = points.map(\.price) + (baseline.map { [$0] } ?? [])
        let low = prices.min() ?? 0, high = prices.max() ?? 1
        let pad = max((high - low) * 0.16, 0.01)
        let bounds = (low - pad)...(high + pad)
        let color = theme.movement((market.change(symbol) ?? 0) >= 0)
        Group {
            if points.count > 1 {
                Chart {
                    if let baseline {
                        RuleMark(y: .value("Previous close", baseline)).foregroundStyle(color.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(points) { point in
                        AreaMark(x: .value("Time", point.date), yStart: .value("Floor", bounds.lowerBound), yEnd: .value("Price", point.price))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.16), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.date), y: .value("Price", point.price)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: bounds)
            } else {
                Rectangle().fill(theme.line.opacity(0.5)).frame(height: 1)
            }
        }.frame(height: 40).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DottedCloseKey: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }.accessibilityHidden(true)
    }
}
