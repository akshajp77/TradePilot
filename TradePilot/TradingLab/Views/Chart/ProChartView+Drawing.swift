import SwiftUI

/// ProChartView's Canvas drawing: candles, overlays, panes, drawings, order lines and labels.
extension ProChartView {
    func draw(_ context: GraphicsContext, layout: Layout, scale: PriceScale) {
        let w = layout.plotWidth, mh = layout.mainHeight
        guard let range = viewport.visibleRange, !data.bars.isEmpty else {
            context.draw(Text("No price data").font(.system(size: 13)).foregroundColor(theme.muted), at: CGPoint(x: w / 2, y: mh / 2))
            return
        }
        let bars = data.bars
        let barWidth = CGFloat(viewport.barWidth(plotWidth: Double(w)))
        var plot = context
        plot.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: layout.size.height - layout.timeHeight)))

        // Session shading and day separators (intraday).
        if data.timeframe.isIntraday {
            var shade = Path(), separators = Path()
            for i in range {
                let bar = bars[i]
                if !data.hours.isRegularSessionPrint(bar.time) {
                    shade.addRect(CGRect(x: x(Double(i), layout) - barWidth / 2, y: 0, width: barWidth, height: mh))
                }
                if i > 0, !data.hours.isSameSessionDay(bars[i - 1].time, bar.time) {
                    let px = x(Double(i), layout) - barWidth / 2
                    separators.move(to: CGPoint(x: px, y: 0)); separators.addLine(to: CGPoint(x: px, y: layout.size.height - layout.timeHeight))
                }
            }
            plot.fill(shade, with: .color(theme.line.opacity(0.22)))
            plot.stroke(separators, with: .color(theme.line), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }

        // Price grid + axis labels.
        let ticks = scale.ticks(maxCount: max(3, Int(mh / 44)))
        var grid = Path()
        for tick in ticks {
            let py = y(tick, scale, layout)
            grid.move(to: CGPoint(x: 0, y: py)); grid.addLine(to: CGPoint(x: w, y: py))
            context.draw(Text(Format.price(tick)).font(.system(size: 10).monospacedDigit()).foregroundColor(theme.muted),
                         at: CGPoint(x: w + 6, y: py), anchor: .leading)
        }
        // Time grid + labels.
        let timeIndices = NiceTicks.timeIndices(bars: bars, visible: range, maxLabels: max(2, Int(w / 90)), hours: data.hours)
        for i in timeIndices {
            let px = x(Double(i), layout)
            grid.move(to: CGPoint(x: px, y: 0)); grid.addLine(to: CGPoint(x: px, y: mh))
            context.draw(Text(timeLabel(bars[i].time)).font(.system(size: 10).monospacedDigit()).foregroundColor(theme.muted),
                         at: CGPoint(x: px, y: layout.size.height - layout.timeHeight / 2))
        }
        plot.stroke(grid, with: .color(theme.line.opacity(0.55)), lineWidth: 0.5)

        // Volume.
        if showVolume {
            let maxVolume = range.map { bars[$0].volume }.max() ?? 0
            if maxVolume > 0 {
                var up = Path(), down = Path()
                for i in range {
                    let bar = bars[i]
                    let height = CGFloat(bar.volume / maxVolume) * layout.volumeHeight
                    let rect = CGRect(x: x(Double(i), layout) - barWidth * 0.35, y: mh - height, width: max(1, barWidth * 0.7), height: height)
                    if bar.isUp { up.addRect(rect) } else { down.addRect(rect) }
                }
                plot.fill(up, with: .color(theme.stockGain.opacity(0.28)))
                plot.fill(down, with: .color(theme.stockLoss.opacity(0.28)))
            }
        }

        // Earnings markers.
        for date in earnings {
            guard let index = ChartAnchoring.index(for: date.addingTimeInterval(9.5 * 3600), in: bars, timeframe: data.timeframe),
                  index >= Double(range.lowerBound) - 1, index <= viewport.rightEdge else { continue }
            let center = CGPoint(x: x(index, layout), y: mh - 10)
            plot.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(theme.warning))
            plot.draw(Text("E").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: center)
        }

        // Price series.
        drawSeries(plot, range: range, layout: layout, scale: scale, barWidth: barWidth)

        // Overlay indicators.
        for series in data.overlays {
            let color = ChartPalette.color(series.config.colorIndex)
            if series.config.kind == .bollinger, series.lines.count == 3 {
                var band = Path()
                let upper = series.lines[0].values, lower = series.lines[2].values
                let defined = range.filter { upper[$0] != nil && lower[$0] != nil }
                if let first = defined.first {
                    band.move(to: CGPoint(x: x(Double(first), layout), y: y(upper[first]!, scale, layout)))
                    for i in defined.dropFirst() { band.addLine(to: CGPoint(x: x(Double(i), layout), y: y(upper[i]!, scale, layout))) }
                    for i in defined.reversed() { band.addLine(to: CGPoint(x: x(Double(i), layout), y: y(lower[i]!, scale, layout))) }
                    band.closeSubpath()
                    plot.fill(band, with: .color(color.opacity(0.07)))
                }
            }
            for line in series.lines {
                plot.stroke(linePath(line.values, range: range, layout: layout) { y($0, scale, layout) },
                            with: .color(line.role == 1 ? color.opacity(0.7) : line.role == 2 ? color.opacity(0.55) : color),
                            lineWidth: line.role == 0 ? 1.6 : 1)
            }
        }

        // Drawings.
        for drawing in drawings { drawDrawing(plot, drawing.kind, selected: drawing.id == selectedDrawing, layout: layout, scale: scale) }
        if case .draw(let start) = dragMode, let end = draftEnd, let tool, let kind = Self.kind(for: tool, start, end) {
            drawDrawing(plot, kind, selected: true, layout: layout, scale: scale)
        }

        // Executions.
        for execution in executions {
            guard let index = ChartAnchoring.index(for: execution.time, in: bars, timeframe: data.timeframe),
                  index >= Double(range.lowerBound) - 1, index <= Double(range.upperBound) + 1 else { continue }
            let px = x(index.rounded(), layout), py = y(execution.price, scale, layout)
            var arrow = Path()
            if execution.side == .buy {
                arrow.move(to: CGPoint(x: px, y: py + 3)); arrow.addLine(to: CGPoint(x: px - 5, y: py + 11)); arrow.addLine(to: CGPoint(x: px + 5, y: py + 11))
            } else {
                arrow.move(to: CGPoint(x: px, y: py - 3)); arrow.addLine(to: CGPoint(x: px - 5, y: py - 11)); arrow.addLine(to: CGPoint(x: px + 5, y: py - 11))
            }
            arrow.closeSubpath()
            plot.fill(arrow, with: .color(execution.side == .buy ? theme.stockGain : theme.stockLoss))
            plot.stroke(arrow, with: .color(theme.paper), lineWidth: 0.8)
        }

        // Position line.
        if let position {
            let py = y(position.price, scale, layout)
            if py >= 0 && py <= mh {
                var line = Path(); line.move(to: CGPoint(x: 0, y: py)); line.addLine(to: CGPoint(x: w, y: py))
                plot.stroke(line, with: .color(theme.accent), lineWidth: 1.2)
                label(context, position.label, at: CGPoint(x: 6, y: py), anchor: .leading,
                      fill: position.isProfit ? theme.stockGain : theme.stockLoss)
            }
        }

        // Order lines (pinned to the edge when off screen).
        for line in orderLines {
            let price = (orderDragPrice != nil && isDragging(line.id)) ? orderDragPrice! : line.price
            var py = y(price, scale, layout)
            let offscreen = py < 0 || py > mh
            py = min(max(py, 8), mh - 8)
            let color: Color = line.kind == .stop ? theme.orange : line.kind == .target ? theme.teal : (line.side == .buy ? theme.stockGain : theme.stockLoss)
            if !offscreen {
                var path = Path(); path.move(to: CGPoint(x: 0, y: py)); path.addLine(to: CGPoint(x: w, y: py))
                plot.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
            }
            let text = (offscreen ? (y(price, scale, layout) < 0 ? "▲ " : "▼ ") : "") + line.label
                + (isDragging(line.id) ? " → \(Format.price(price))" : "")
            label(context, text, at: CGPoint(x: w - 34, y: py), anchor: .trailing, fill: color)
            if line.draggable && !offscreen {
                plot.fill(Path(roundedRect: CGRect(x: w - 30, y: py - 6, width: 22, height: 12), cornerRadius: 3), with: .color(color))
                plot.draw(Text("≡").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: w - 19, y: py))
            }
        }

        // Last price line + axis label.
        if let lastPrice {
            let py = y(lastPrice, scale, layout)
            if py >= 0 && py <= mh {
                let up = lastPrice >= (data.previousClose ?? bars.last?.open ?? lastPrice)
                let color = theme.movement(up)
                var line = Path(); line.move(to: CGPoint(x: 0, y: py)); line.addLine(to: CGPoint(x: w, y: py))
                plot.stroke(line, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                label(context, Format.price(lastPrice), at: CGPoint(x: w + 2, y: py), anchor: .leading, fill: color, width: layout.axisWidth - 4)
            }
        }
        if let previousClose = data.previousClose, data.timeframe.isIntraday {
            let py = y(previousClose, scale, layout)
            if py >= 0 && py <= mh {
                var line = Path(); line.move(to: CGPoint(x: 0, y: py)); line.addLine(to: CGPoint(x: w, y: py))
                plot.stroke(line, with: .color(theme.muted.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [1, 4]))
            }
        }

        // Measure.
        if let measurement, let a = screenPoint(of: measurement.start, layout: layout, scale: scale),
           let b = screenPoint(of: measurement.end, layout: layout, scale: scale) {
            let up = measurement.change >= 0
            let color = theme.movement(up)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            plot.fill(Path(rect), with: .color(color.opacity(0.12)))
            plot.stroke(Path(rect), with: .color(color), lineWidth: 1)
            let text = "\(Format.price(measurement.change)) (\(Format.percent(measurement.percent / 100))) · \(abs(measurement.bars)) bars"
            label(context, text, at: CGPoint(x: rect.midX, y: up ? rect.minY - 12 : rect.maxY + 12), anchor: .center, fill: color)
        }

        // Indicator panes.
        for (i, series) in data.panes.enumerated() { drawPane(context, series, index: i, range: range, layout: layout, barWidth: barWidth) }

        // Crosshair.
        if let point = crosshair, let index = barIndex(atX: point.x, layout) {
            let px = x(Double(index), layout)
            var cross = Path()
            cross.move(to: CGPoint(x: px, y: 0)); cross.addLine(to: CGPoint(x: px, y: layout.size.height - layout.timeHeight))
            cross.move(to: CGPoint(x: 0, y: point.y)); cross.addLine(to: CGPoint(x: w, y: point.y))
            context.stroke(cross, with: .color(theme.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            let price = scale.price(atY: Double(point.y), height: Double(mh))
            label(context, Format.price(price), at: CGPoint(x: w + 2, y: point.y), anchor: .leading, fill: theme.ink, width: layout.axisWidth - 4)
            label(context, crosshairTime(bars[index].time), at: CGPoint(x: px, y: layout.size.height - layout.timeHeight / 2), anchor: .center, fill: theme.ink)
        }
    }

    private func isDragging(_ id: UUID) -> Bool { if case .order(let current) = dragMode { return current == id } else { return false } }

    private func drawSeries(_ context: GraphicsContext, range: ClosedRange<Int>, layout: Layout, scale: PriceScale, barWidth: CGFloat) {
        let bars = data.bars
        switch style {
        case .line, .area:
            var path = Path()
            for (n, i) in range.enumerated() {
                let point = CGPoint(x: x(Double(i), layout), y: y(bars[i].close, scale, layout))
                if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let up = (bars.last?.close ?? 0) >= (bars[range.lowerBound].close)
            let color = theme.movement(up)
            if style == .area {
                var fill = path
                fill.addLine(to: CGPoint(x: x(Double(range.upperBound), layout), y: layout.mainHeight))
                fill.addLine(to: CGPoint(x: x(Double(range.lowerBound), layout), y: layout.mainHeight))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.25), color.opacity(0.02)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: layout.mainHeight)))
            }
            context.stroke(path, with: .color(color), lineWidth: 1.8)
        case .candles, .hollow, .heikinAshi, .bars:
            var upWicks = Path(), downWicks = Path(), upBodies = Path(), downBodies = Path()
            let bodyWidth = max(1, barWidth * 0.68)
            for i in range {
                let bar = bars[i]
                let cx = x(Double(i), layout)
                let high = y(bar.high, scale, layout), low = y(bar.low, scale, layout)
                let open = y(bar.open, scale, layout), close = y(bar.close, scale, layout)
                if style == .bars {
                    var p = Path()
                    p.move(to: CGPoint(x: cx, y: high)); p.addLine(to: CGPoint(x: cx, y: low))
                    p.move(to: CGPoint(x: cx - bodyWidth / 2, y: open)); p.addLine(to: CGPoint(x: cx, y: open))
                    p.move(to: CGPoint(x: cx, y: close)); p.addLine(to: CGPoint(x: cx + bodyWidth / 2, y: close))
                    if bar.isUp { upWicks.addPath(p) } else { downWicks.addPath(p) }
                    continue
                }
                var wick = Path()
                wick.move(to: CGPoint(x: cx, y: high)); wick.addLine(to: CGPoint(x: cx, y: low))
                let body = CGRect(x: cx - bodyWidth / 2, y: min(open, close), width: bodyWidth, height: max(1, abs(close - open)))
                if bar.isUp { upWicks.addPath(wick); upBodies.addRect(body) } else { downWicks.addPath(wick); downBodies.addRect(body) }
            }
            let lineWidth: CGFloat = style == .bars ? max(1, min(2, barWidth * 0.15)) : 1
            context.stroke(upWicks, with: .color(theme.stockGain), lineWidth: lineWidth)
            context.stroke(downWicks, with: .color(theme.stockLoss), lineWidth: lineWidth)
            if style == .hollow {
                context.fill(upBodies, with: .color(theme.paper))
                context.stroke(upBodies, with: .color(theme.stockGain), lineWidth: 1)
            } else {
                context.fill(upBodies, with: .color(theme.stockGain))
            }
            context.fill(downBodies, with: .color(theme.stockLoss))
        }
    }

    private func linePath(_ values: [Double?], range: ClosedRange<Int>, layout: Layout, y toY: (Double) -> CGFloat) -> Path {
        var path = Path()
        var drawing = false
        for i in range where i < values.count {
            guard let value = values[i] else { drawing = false; continue }
            let point = CGPoint(x: x(Double(i), layout), y: toY(value))
            if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
        }
        return path
    }

    private func drawDrawing(_ context: GraphicsContext, _ kind: DrawingKind, selected: Bool, layout: Layout, scale: PriceScale) {
        let color = theme.accent
        let width: CGFloat = selected ? 2.2 : 1.4
        let w = layout.plotWidth
        switch kind {
        case .horizontal(let price):
            let py = y(price, scale, layout)
            var p = Path(); p.move(to: CGPoint(x: 0, y: py)); p.addLine(to: CGPoint(x: w, y: py))
            context.stroke(p, with: .color(color), lineWidth: width)
            label(context, Format.price(price), at: CGPoint(x: w + 2, y: py), anchor: .leading, fill: color, width: layout.axisWidth - 4)
        case .trend(let a, let b), .ray(let a, let b):
            guard let pa = screenPoint(of: a, layout: layout, scale: scale), var pb = screenPoint(of: b, layout: layout, scale: scale) else { return }
            if case .ray = kind, pb.x != pa.x {
                let slope = (pb.y - pa.y) / (pb.x - pa.x)
                let edge = pb.x >= pa.x ? w : 0
                pb = CGPoint(x: edge, y: pa.y + slope * (edge - pa.x))
            }
            var p = Path(); p.move(to: pa); p.addLine(to: pb)
            context.stroke(p, with: .color(color), lineWidth: width)
            if selected { for handle in [pa, pb] { context.fill(Path(ellipseIn: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8)), with: .color(color)) } }
        case .rectangle(let a, let b):
            guard let pa = screenPoint(of: a, layout: layout, scale: scale), let pb = screenPoint(of: b, layout: layout, scale: scale) else { return }
            let rect = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pb.x - pa.x), height: abs(pb.y - pa.y))
            context.fill(Path(rect), with: .color(color.opacity(0.10)))
            context.stroke(Path(rect), with: .color(color), lineWidth: width)
        case .fibonacci(let a, let b):
            guard let pa = screenPoint(of: a, layout: layout, scale: scale) else { return }
            for level in DrawingKind.fibLevels {
                let price = b.price + (a.price - b.price) * level
                let py = y(price, scale, layout)
                var p = Path(); p.move(to: CGPoint(x: pa.x, y: py)); p.addLine(to: CGPoint(x: w, y: py))
                context.stroke(p, with: .color(color.opacity(level == 0.5 || level == 0.618 ? 1 : 0.6)), lineWidth: selected ? 1.6 : 1)
                context.draw(Text("\(String(format: "%.3g", level)) (\(Format.price(price)))").font(.system(size: 9).monospacedDigit()).foregroundColor(color),
                             at: CGPoint(x: pa.x + 4, y: py - 6), anchor: .leading)
            }
        }
    }

    private func drawPane(_ context: GraphicsContext, _ series: IndicatorSeries, index: Int, range: ClosedRange<Int>, layout: Layout, barWidth: CGFloat) {
        let top = layout.paneTop(index), height = layout.paneHeight, w = layout.plotWidth
        var separator = Path(); separator.move(to: CGPoint(x: 0, y: top)); separator.addLine(to: CGPoint(x: layout.size.width, y: top))
        context.stroke(separator, with: .color(theme.line), lineWidth: 1)
        guard let extent = series.range.map({ ($0.lowerBound, $0.upperBound) }) ?? series.extent(in: range) else { return }
        let scale = PriceScale(low: extent.0, high: extent.1, padding: series.range == nil ? 0.1 : 0.04)
        func py(_ v: Double) -> CGFloat { top + CGFloat(scale.y(v, height: Double(height))) }
        var pane = context
        pane.clip(to: Path(CGRect(x: 0, y: top, width: w, height: height)))
        for level in series.levels {
            var p = Path(); p.move(to: CGPoint(x: 0, y: py(level))); p.addLine(to: CGPoint(x: w, y: py(level)))
            pane.stroke(p, with: .color(theme.muted.opacity(0.5)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            context.draw(Text(Format.price(level)).font(.system(size: 9)).foregroundColor(theme.muted), at: CGPoint(x: w + 6, y: py(level)), anchor: .leading)
        }
        if let histogram = series.histogram {
            var positive = Path(), negative = Path()
            for i in range where i < histogram.count {
                guard let value = histogram[i] else { continue }
                let zero = py(0), v = py(value)
                let rect = CGRect(x: x(Double(i), layout) - barWidth * 0.35, y: min(zero, v), width: max(1, barWidth * 0.7), height: abs(v - zero))
                if value >= 0 { positive.addRect(rect) } else { negative.addRect(rect) }
            }
            pane.fill(positive, with: .color(theme.stockGain.opacity(0.5)))
            pane.fill(negative, with: .color(theme.stockLoss.opacity(0.5)))
        }
        let color = ChartPalette.color(series.config.colorIndex)
        for line in series.lines {
            pane.stroke(linePath(line.values, range: range, layout: layout, y: py), with: .color(line.role == 2 ? theme.orange : color), lineWidth: 1.4)
        }
        let lastValue = series.lines.first?.values[safe: range.upperBound] ?? nil
        let title = series.config.title + (lastValue.map { "  \(Format.price($0))" } ?? "")
        context.draw(Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(color), at: CGPoint(x: 8, y: top + 9), anchor: .leading)
    }

    func label(_ context: GraphicsContext, _ text: String, at point: CGPoint, anchor: UnitPoint, fill: Color, width: CGFloat? = nil) {
        let resolved = context.resolve(Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(.white))
        let size = resolved.measure(in: CGSize(width: 400, height: 40))
        let boxWidth = width ?? size.width + 10
        let origin: CGPoint
        switch anchor {
        case .leading: origin = CGPoint(x: point.x, y: point.y - 8)
        case .trailing: origin = CGPoint(x: point.x - boxWidth, y: point.y - 8)
        default: origin = CGPoint(x: point.x - boxWidth / 2, y: point.y - 8)
        }
        let rect = CGRect(origin: origin, size: CGSize(width: boxWidth, height: 16))
        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill))
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func timeLabel(_ date: Date) -> String {
        let et = data.hours.timeZone
        switch data.timeframe {
        case .m1, .m5, .m15, .h1:
            var style = Date.FormatStyle(timeZone: et).hour(.twoDigits(amPM: .omitted)).minute()
            let components = data.hours.calendar.dateComponents([.hour, .minute], from: date)
            if components.hour == 9 && components.minute == 30 || components.hour == 4 && components.minute == 0 {
                style = Date.FormatStyle(timeZone: et).month(.abbreviated).day()
            }
            return date.formatted(style)
        case .d1: return date.formatted(Date.FormatStyle(timeZone: et).month(.abbreviated).day())
        case .w1: return date.formatted(Date.FormatStyle(timeZone: et).month(.abbreviated).year(.twoDigits))
        }
    }

    func crosshairTime(_ date: Date) -> String {
        let et = data.hours.timeZone
        return data.timeframe.isIntraday
            ? date.formatted(Date.FormatStyle(timeZone: et).month(.abbreviated).day().hour().minute())
            : date.formatted(Date.FormatStyle(timeZone: et).month(.abbreviated).day().year())
    }
}
