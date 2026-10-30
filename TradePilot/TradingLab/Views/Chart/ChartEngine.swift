import SwiftUI

/// A Canvas-rendered trading chart: pan, pinch zoom, long-press crosshair (hover on Mac), drawing
/// tools, a measure tool, and order lines that can be dragged to new prices.
struct ProChartView: View {
    @Environment(\.theme) var theme
    let data: ChartData
    let style: ChartStyle
    var showVolume = true
    /// Changing this (symbol, timeframe) resets zoom to the latest bars.
    let resetKey: String
    var orderLines: [ChartOrderLine] = []
    var position: ChartPositionLine?
    var executions: [ChartExecution] = []
    var drawings: [ChartDrawing] = []
    var earnings: [Date] = []
    var lastPrice: Double?
    @Binding var tool: DrawingTool?
    var magnet = true
    var onAddDrawing: (DrawingKind) -> Void = { _ in }
    var onDeleteDrawing: (String) -> Void = { _ in }
    var onMoveOrder: (UUID, Double) -> Void = { _, _ in }
    /// "+" at the crosshair: trade or alert at that price.
    var onPriceAction: ((Double) -> Void)?

    @State var viewport = ChartViewport.initial(barCount: 0)
    @State var crosshair: CGPoint?
    @State var dragMode: DragMode = .idle
    @State private var panStart: ChartViewport?
    @State private var pinchStart: ChartViewport?
    @State var draftEnd: ChartPoint?
    @State var orderDragPrice: Double?
    @State var selectedDrawing: String?
    @State var measurement: ChartMeasurement?

    enum DragMode { case idle, pan, crosshair, order(UUID), draw(ChartPoint), measure(ChartPoint) }

    // MARK: Layout

    struct Layout {
        let size: CGSize
        let axisWidth: CGFloat = 60
        let timeHeight: CGFloat = 20
        let paneHeight: CGFloat
        let panes: Int
        var plotWidth: CGFloat { max(10, size.width - axisWidth) }
        var mainHeight: CGFloat { max(60, size.height - timeHeight - CGFloat(panes) * paneHeight) }
        func paneTop(_ i: Int) -> CGFloat { mainHeight + CGFloat(i) * paneHeight }
        var volumeHeight: CGFloat { mainHeight * 0.18 }

        init(size: CGSize, panes: Int) {
            self.size = size
            self.panes = panes
            paneHeight = min(90, max(56, size.height * 0.16))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(size: geometry.size, panes: data.panes.count)
            let scale = mainScale(layout: layout)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(context, layout: layout, scale: scale)
                }
                legend(layout: layout).padding(.leading, 8).padding(.top, 6).allowsHitTesting(false)
                overlayButtons(layout: layout, scale: scale)
            }
            .contentShape(Rectangle())
            .gesture(crosshairGesture(layout: layout).exclusively(before: dragGesture(layout: layout, scale: scale)))
            .simultaneousGesture(pinchGesture(layout: layout))
            .onTapGesture(coordinateSpace: .local) { location in tap(at: location, layout: layout, scale: scale) }
            #if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard case .idle = dragMode else { return }
                switch phase {
                case .active(let point): crosshair = point.x < layout.plotWidth && point.y < layout.mainHeight ? point : nil
                case .ended: crosshair = nil
                }
            }
            .contextMenu {
                if let onPriceAction, let point = crosshair {
                    let price = scale.price(atY: point.y, height: layout.mainHeight)
                    Button("Trade at \(Format.price(price))…") { onPriceAction(price) }
                }
            }
            #endif
        }
        .onAppear { viewport = .initial(barCount: data.bars.count) }
        .onChange(of: resetKey) { _, _ in
            viewport = .initial(barCount: data.bars.count)
            crosshair = nil; measurement = nil; selectedDrawing = nil
        }
        .onChange(of: data.bars.count) { _, count in viewport.update(barCount: count) }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let last = data.bars.last else { return "Chart with no data" }
        return "Price chart, \(data.timeframe.label) bars. Last \(Format.price(last.close)), high \(Format.price(last.high)), low \(Format.price(last.low))."
    }

    // MARK: Scales

    private func mainScale(layout: Layout) -> PriceScale {
        guard let range = viewport.visibleRange else { return PriceScale(low: 0, high: 1) }
        var extra: [Double] = []
        for series in data.overlays { if let e = series.extent(in: range) { extra += [e.0, e.1] } }
        if let lastPrice { extra.append(lastPrice) }
        return PriceScale.fit(bars: data.bars, range: range, include: extra, padding: 0.06)
    }

    func y(_ price: Double, _ scale: PriceScale, _ layout: Layout) -> CGFloat {
        CGFloat(scale.y(price, height: Double(layout.mainHeight)))
    }

    func x(_ index: Double, _ layout: Layout) -> CGFloat {
        CGFloat(viewport.x(for: index, plotWidth: Double(layout.plotWidth)))
    }

    func barIndex(atX px: CGFloat, _ layout: Layout) -> Int? {
        guard !data.bars.isEmpty else { return nil }
        let i = Int(viewport.index(atX: Double(px), plotWidth: Double(layout.plotWidth)).rounded())
        return min(max(0, i), data.bars.count - 1)
    }

    private func chartPoint(at point: CGPoint, layout: Layout, scale: PriceScale, snap: Bool) -> ChartPoint {
        let fractional = viewport.index(atX: Double(point.x), plotWidth: Double(layout.plotWidth))
        var price = scale.price(atY: Double(point.y), height: Double(layout.mainHeight))
        var index = fractional
        if snap, magnet, let i = barIndex(atX: point.x, layout) {
            index = Double(i)
            let bar = data.bars[i]
            let candidates = [bar.open, bar.high, bar.low, bar.close]
            if let nearest = candidates.min(by: { abs($0 - price) < abs($1 - price) }),
               abs(y(nearest, scale, layout) - point.y) < 16 { price = nearest }
        }
        let time = ChartAnchoring.time(for: index, in: data.bars, timeframe: data.timeframe) ?? Date()
        return ChartPoint(time: time, price: price)
    }

    func screenPoint(of point: ChartPoint, layout: Layout, scale: PriceScale) -> CGPoint? {
        guard let index = ChartAnchoring.index(for: point.time, in: data.bars, timeframe: data.timeframe) else { return nil }
        return CGPoint(x: x(index, layout), y: y(point.price, scale, layout))
    }

    // MARK: Gestures

    private func crosshairGesture(layout: Layout) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard tool == nil else { return }
                if case .second(true, let drag) = value, let drag {
                    crosshair = CGPoint(x: min(drag.location.x, layout.plotWidth), y: min(max(0, drag.location.y), layout.mainHeight))
                }
            }
    }

    private func dragGesture(layout: Layout, scale: PriceScale) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if case .idle = dragMode {
                    if let tool {
                        let start = chartPoint(at: value.startLocation, layout: layout, scale: scale, snap: true)
                        dragMode = tool == .measure ? .measure(start) : .draw(start)
                    } else if crosshair != nil {
                        dragMode = .crosshair
                    } else if let line = orderLineNear(y: value.startLocation.y, layout: layout, scale: scale) {
                        dragMode = .order(line)
                    } else {
                        dragMode = .pan
                        panStart = viewport
                    }
                }
                switch dragMode {
                case .pan:
                    guard var vp = panStart else { return }
                    vp.pan(byPoints: Double(value.translation.width), plotWidth: Double(layout.plotWidth))
                    viewport = vp
                case .crosshair:
                    crosshair = CGPoint(x: min(value.location.x, layout.plotWidth), y: min(max(0, value.location.y), layout.mainHeight))
                case .order:
                    orderDragPrice = scale.price(atY: Double(value.location.y), height: Double(layout.mainHeight))
                case .draw:
                    draftEnd = chartPoint(at: value.location, layout: layout, scale: scale, snap: true)
                case .measure(let start):
                    let end = chartPoint(at: value.location, layout: layout, scale: scale, snap: false)
                    let a = ChartAnchoring.index(for: start.time, in: data.bars, timeframe: data.timeframe) ?? 0
                    let b = ChartAnchoring.index(for: end.time, in: data.bars, timeframe: data.timeframe) ?? 0
                    measurement = ChartMeasurement(start: start, end: end, bars: Int((b - a).rounded()))
                case .idle: break
                }
            }
            .onEnded { _ in
                switch dragMode {
                case .order(let id):
                    if let price = orderDragPrice { onMoveOrder(id, price) }
                case .draw(let start):
                    if let end = draftEnd, let tool, let kind = Self.kind(for: tool, start, end) {
                        onAddDrawing(kind)
                        self.tool = nil
                    }
                case .measure:
                    tool = nil
                default: break
                }
                dragMode = .idle
                panStart = nil
                draftEnd = nil
                orderDragPrice = nil
            }
    }

    private func pinchGesture(layout: Layout) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = viewport }
                guard var vp = pinchStart else { return }
                vp.zoom(by: Double(value.magnification), anchor: Double(min(1, max(0, value.startLocation.x / layout.plotWidth))))
                viewport = vp
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func tap(at location: CGPoint, layout: Layout, scale: PriceScale) {
        if tool == .horizontal {
            let point = chartPoint(at: location, layout: layout, scale: scale, snap: true)
            onAddDrawing(.horizontal(price: point.price))
            tool = nil
            return
        }
        if crosshair != nil { crosshair = nil; return }
        if measurement != nil { measurement = nil; return }
        selectedDrawing = drawingNear(location, layout: layout, scale: scale)
    }

    static func kind(for tool: DrawingTool, _ a: ChartPoint, _ b: ChartPoint) -> DrawingKind? {
        switch tool {
        case .horizontal: return .horizontal(price: b.price)
        case .trend: return .trend(a, b)
        case .ray: return .ray(a, b)
        case .rectangle: return .rectangle(a, b)
        case .fibonacci: return .fibonacci(a, b)
        case .measure: return nil
        }
    }

    private func orderLineNear(y py: CGFloat, layout: Layout, scale: PriceScale) -> UUID? {
        orderLines.filter(\.draggable)
            .map { ($0.id, abs(y($0.price, scale, layout) - py)) }
            .filter { $0.1 < 14 }
            .min { $0.1 < $1.1 }?.0
    }

    private func drawingNear(_ point: CGPoint, layout: Layout, scale: PriceScale) -> String? {
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
        var best: (String, CGFloat)?
        for drawing in drawings {
            var d = CGFloat.infinity
            switch drawing.kind {
            case .horizontal(let price): d = abs(y(price, scale, layout) - point.y)
            case .trend(let a, let b), .ray(let a, let b), .fibonacci(let a, let b):
                if let pa = screenPoint(of: a, layout: layout, scale: scale), let pb = screenPoint(of: b, layout: layout, scale: scale) { d = distance(point, pa, pb) }
            case .rectangle(let a, let b):
                if let pa = screenPoint(of: a, layout: layout, scale: scale), let pb = screenPoint(of: b, layout: layout, scale: scale) {
                    let rect = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pb.x - pa.x), height: abs(pb.y - pa.y))
                    d = rect.insetBy(dx: -8, dy: -8).contains(point) ? 0 : .infinity
                }
            }
            if d < 12, d < (best?.1 ?? .infinity) { best = (drawing.id, d) }
        }
        return best?.0
    }

    // MARK: Overlays (SwiftUI)

    @ViewBuilder
    private func legend(layout: Layout) -> some View {
        let index = crosshair.flatMap { barIndex(atX: $0.x, layout) } ?? (data.bars.isEmpty ? nil : data.bars.count - 1)
        if let index, index < data.bars.count {
            let bar = data.bars[index]
            let previous = index > 0 ? data.bars[index - 1].close : bar.open
            let change = previous > 0 ? (bar.close / previous - 1) * 100 : 0
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    legendValue("O", bar.open); legendValue("H", bar.high); legendValue("L", bar.low); legendValue("C", bar.close)
                    Text(Format.percent(change / 100)).foregroundStyle(theme.movement(change >= 0))
                    if showVolume { Text("V \(Format.compact(bar.volume))").foregroundStyle(theme.muted) }
                }
                ForEach(data.overlays, id: \.config.id) { series in
                    if let value = series.lines.first(where: { $0.role == 0 })?.values[safe: index] ?? nil {
                        Text("\(series.config.title) \(Format.price(value))").foregroundStyle(ChartPalette.color(series.config.colorIndex))
                    }
                }
                if crosshair != nil {
                    Text(crosshairTime(bar.time)).foregroundStyle(theme.muted)
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .padding(4)
            .background(theme.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func legendValue(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(theme.muted)
            Text(Format.price(value)).foregroundStyle(theme.ink)
        }
    }

    @ViewBuilder
    private func overlayButtons(layout: Layout, scale: PriceScale) -> some View {
        if let onPriceAction, let point = crosshair {
            let price = scale.price(atY: Double(point.y), height: Double(layout.mainHeight))
            Button { onPriceAction(price) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .position(x: layout.plotWidth - 16, y: max(14, min(layout.mainHeight - 14, point.y)))
            .accessibilityLabel("Trade or alert at \(Format.price(price))")
        }
        if let id = selectedDrawing {
            Button(role: .destructive) { onDeleteDrawing(id); selectedDrawing = nil } label: {
                Label("Delete drawing", systemImage: "trash").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6).background(theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(theme.line))
            }
            .buttonStyle(.plain)
            .position(x: layout.plotWidth / 2, y: 22)
        }
        if !viewport.isAtLatest {
            Button { withAnimation(.easeOut(duration: 0.2)) { viewport.scrollToLatest() } } label: {
                Image(systemName: "chevron.right.2").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink)
                    .frame(width: 28, height: 28).background(theme.surface, in: Circle()).overlay(Circle().stroke(theme.line))
            }
            .buttonStyle(.plain)
            .position(x: layout.plotWidth - 20, y: layout.mainHeight - 20)
            .accessibilityLabel("Jump to latest bar")
        }
    }
}
