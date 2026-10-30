import SwiftUI

/// A small "?" that explains a term in plain words. Put it next to any jargon.
struct ExplainButton: View {
    @Environment(\.theme) private var theme
    let term: String
    var size: CGFloat = 13
    @State private var showing = false

    var body: some View {
        if let entry = Curriculum.term(term) {
            Button { showing = true } label: {
                Image(systemName: "questionmark.circle").font(.system(size: size)).foregroundStyle(theme.muted)
                    .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What is \(entry.term)?")
            .sheet(isPresented: $showing) { GlossarySheet(entry: entry).environment(\.theme, theme) }
        }
    }
}

/// Text with a dotted underline that opens the glossary entry when tapped.
struct TermLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    var term: String? = nil
    @State private var showing = false
    var body: some View {
        if let entry = Curriculum.term(term ?? text) {
            Button { showing = true } label: {
                Text(text).underline(pattern: .dot, color: theme.muted).holdToExplain("Term", value: entry.term, term: entry.term)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Explains \(entry.term)")
            .sheet(isPresented: $showing) { GlossarySheet(entry: entry).environment(\.theme, theme) }
        } else {
            Text(text)
        }
    }
}

struct GlossarySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: GlossaryEntry
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Text(entry.term).font(theme.page)
                    if let graphic = entry.graphic {
                        ConceptGraphic(kind: graphic).frame(height: 150)
                            .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                    }
                    Text(entry.explanation).font(theme.body).lineSpacing(4)
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Example")
                        Text(entry.example).font(theme.body).foregroundStyle(theme.muted).lineSpacing(3)
                    }
                    if let lesson = Curriculum.content.pathLessons.first(where: { $0.terms.contains { Curriculum.term($0)?.term == entry.term } }) {
                        Text("Covered in the lesson \"\(lesson.title)\" in Learn.").font(theme.meta).foregroundStyle(theme.muted)
                    }
                }
                .padding(Space.s24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(theme.paper)
            .navigationTitle("Explained").appInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Simple diagrams for concepts, drawn in code so they follow the theme and Dynamic Type.
struct ConceptGraphic: View {
    @Environment(\.theme) private var theme
    let kind: String

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let up = theme.stockGain, down = theme.stockLoss, ink = theme.ink, muted = theme.muted, accent = theme.accent
            func line(_ points: [CGPoint], _ color: Color, width: CGFloat = 2, dash: [CGFloat] = []) {
                var p = Path(); guard let first = points.first else { return }
                p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            }
            func label(_ text: String, at point: CGPoint, _ color: Color = muted, anchor: UnitPoint = .leading) {
                context.draw(Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(color), at: point, anchor: anchor)
            }
            func zigzag(_ ys: [CGFloat]) -> [CGPoint] {
                ys.enumerated().map { CGPoint(x: w * 0.06 + CGFloat($0.offset) * (w * 0.88 / CGFloat(max(1, ys.count - 1))), y: h * $0.element) }
            }
            func candle(x: CGFloat, open: CGFloat, close: CGFloat, high: CGFloat, low: CGFloat, width bw: CGFloat) {
                let color = close < open ? up : down   // y grows downward
                line([CGPoint(x: x, y: h * high), CGPoint(x: x, y: h * low)], color, width: 1.5)
                let top = min(open, close) * h, bottom = max(open, close) * h
                context.fill(Path(CGRect(x: x - bw / 2, y: top, width: bw, height: max(2, bottom - top))), with: .color(color))
            }

            switch kind {
            case "candle":
                candle(x: w * 0.3, open: 0.7, close: 0.3, high: 0.12, low: 0.85, width: 26)
                label("High", at: CGPoint(x: w * 0.3 + 20, y: h * 0.12)); label("Close", at: CGPoint(x: w * 0.3 + 20, y: h * 0.3))
                label("Open", at: CGPoint(x: w * 0.3 + 20, y: h * 0.7)); label("Low", at: CGPoint(x: w * 0.3 + 20, y: h * 0.85))
                candle(x: w * 0.72, open: 0.3, close: 0.65, high: 0.2, low: 0.8, width: 26)
                label("Up candle", at: CGPoint(x: w * 0.3, y: h * 0.97), up, anchor: .center)
                label("Down candle", at: CGPoint(x: w * 0.72, y: h * 0.97), down, anchor: .center)
            case "spread":
                line([CGPoint(x: w * 0.1, y: h * 0.35), CGPoint(x: w * 0.9, y: h * 0.35)], up)
                line([CGPoint(x: w * 0.1, y: h * 0.65), CGPoint(x: w * 0.9, y: h * 0.65)], down)
                label("Ask $100.02: what buyers pay", at: CGPoint(x: w * 0.1, y: h * 0.25), up)
                label("Bid $99.98: what sellers get", at: CGPoint(x: w * 0.1, y: h * 0.77), down)
                context.fill(Path(CGRect(x: w * 0.75, y: h * 0.35, width: 6, height: h * 0.3)), with: .color(accent.opacity(0.5)))
                label("Spread", at: CGPoint(x: w * 0.75 - 6, y: h * 0.5), accent, anchor: .trailing)
            case "stopLoss":
                let path = zigzag([0.5, 0.42, 0.48, 0.38, 0.55, 0.62, 0.75, 0.82])
                line(Array(path.prefix(4)), ink)
                line(Array(path.suffix(5)), down)
                line([CGPoint(x: 0, y: h * 0.62), CGPoint(x: w, y: h * 0.62)], down, width: 1.5, dash: [5, 4])
                label("Stop loss: you're out here", at: CGPoint(x: w * 0.02, y: h * 0.7), down)
                label("Bought here", at: CGPoint(x: path[1].x, y: path[1].y - 12), ink, anchor: .center)
            case "trend":
                line(zigzag([0.85, 0.6, 0.7, 0.45, 0.55, 0.3, 0.4, 0.15]), up)
                label("Higher highs, higher lows = uptrend", at: CGPoint(x: w * 0.06, y: h * 0.95), up)
            case "supportResistance":
                line([CGPoint(x: 0, y: h * 0.25), CGPoint(x: w, y: h * 0.25)], down, width: 1.5, dash: [5, 4])
                line([CGPoint(x: 0, y: h * 0.75), CGPoint(x: w, y: h * 0.75)], up, width: 1.5, dash: [5, 4])
                line(zigzag([0.6, 0.27, 0.73, 0.28, 0.72, 0.5, 0.26, 0.1]), ink)
                label("Resistance (ceiling)", at: CGPoint(x: w * 0.02, y: h * 0.17), down)
                label("Support (floor)", at: CGPoint(x: w * 0.02, y: h * 0.85), up)
            case "volume":
                let heights: [CGFloat] = [0.2, 0.25, 0.18, 0.22, 0.2, 0.75, 0.3]
                for (i, v) in heights.enumerated() {
                    let x = w * 0.1 + CGFloat(i) * w * 0.12
                    context.fill(Path(CGRect(x: x, y: h * (0.9 - v), width: w * 0.08, height: h * v)), with: .color(i == 5 ? accent : muted.opacity(0.4)))
                }
                label("Big volume: lots of interest", at: CGPoint(x: w * 0.1 + 5 * w * 0.12 + w * 0.04, y: h * 0.08), accent, anchor: .center)
            case "movingAverage":
                line(zigzag([0.8, 0.55, 0.7, 0.45, 0.6, 0.35, 0.5, 0.25, 0.35]), muted)
                line(zigzag([0.75, 0.68, 0.62, 0.56, 0.5, 0.45, 0.4, 0.35, 0.32]), accent, width: 3)
                label("Moving average smooths out the noise", at: CGPoint(x: w * 0.06, y: h * 0.95), accent)
            case "vwap":
                line(zigzag([0.5, 0.4, 0.45, 0.3, 0.38, 0.25, 0.3, 0.2]), up)
                line([CGPoint(x: w * 0.06, y: h * 0.5), CGPoint(x: w * 0.94, y: h * 0.4)], accent, width: 2, dash: [6, 3])
                label("VWAP: today's average price", at: CGPoint(x: w * 0.4, y: h * 0.58), accent)
                label("Price above VWAP: buyers in control", at: CGPoint(x: w * 0.06, y: h * 0.1), up)
            case "rsi":
                line([CGPoint(x: 0, y: h * 0.3), CGPoint(x: w, y: h * 0.3)], down, width: 1, dash: [4, 4])
                line([CGPoint(x: 0, y: h * 0.7), CGPoint(x: w, y: h * 0.7)], up, width: 1, dash: [4, 4])
                line(zigzag([0.5, 0.35, 0.22, 0.28, 0.45, 0.6, 0.78, 0.65, 0.5]), accent)
                label("70: strong buying lately", at: CGPoint(x: w * 0.98, y: h * 0.24), down, anchor: .trailing)
                label("30: strong selling lately", at: CGPoint(x: w * 0.98, y: h * 0.78), up, anchor: .trailing)
            case "recovery":
                let pairs: [(String, CGFloat, CGFloat)] = [("−10%", 0.1, 0.11), ("−25%", 0.25, 0.33), ("−50%", 0.5, 1.0)]
                for (i, pair) in pairs.enumerated() {
                    let y = h * (0.15 + CGFloat(i) * 0.3)
                    context.fill(Path(CGRect(x: w * 0.2, y: y, width: w * 0.35 * pair.1, height: 12)), with: .color(down))
                    context.fill(Path(CGRect(x: w * 0.2, y: y + 14, width: w * 0.35 * pair.2, height: 12)), with: .color(up))
                    label(pair.0, at: CGPoint(x: w * 0.18, y: y + 6), down, anchor: .trailing)
                    label("needs +\(Int(pair.2 * 100))%", at: CGPoint(x: w * 0.2 + w * 0.35 * pair.2 + 6, y: y + 20), up)
                }
            case "riskReward", "bracket":
                line(zigzag([0.55, 0.5, 0.52, 0.45, 0.4, 0.3, 0.22]), ink)
                line([CGPoint(x: 0, y: h * 0.15), CGPoint(x: w, y: h * 0.15)], up, width: 1.5, dash: [5, 4])
                line([CGPoint(x: 0, y: h * 0.55), CGPoint(x: w, y: h * 0.55)], muted, width: 1)
                line([CGPoint(x: 0, y: h * 0.75), CGPoint(x: w, y: h * 0.75)], down, width: 1.5, dash: [5, 4])
                label(kind == "bracket" ? "Profit target (sell limit)" : "Target: +$2 a share (reward)", at: CGPoint(x: w * 0.02, y: h * 0.08), up)
                label("Entry", at: CGPoint(x: w * 0.02, y: h * 0.62), muted)
                label(kind == "bracket" ? "Stop loss (sell stop)" : "Stop: −$1 a share (risk)", at: CGPoint(x: w * 0.02, y: h * 0.83), down)
            case "compound":
                let years = 30
                var pts: [CGPoint] = [], flat: [CGPoint] = []
                for y in 0...years {
                    let v = pow(1.08, Double(y)), simple = 1 + 0.08 * Double(y)
                    let x = w * 0.06 + w * 0.88 * CGFloat(y) / CGFloat(years)
                    pts.append(CGPoint(x: x, y: h * 0.9 - h * 0.8 * CGFloat(v / 10.06)))
                    flat.append(CGPoint(x: x, y: h * 0.9 - h * 0.8 * CGFloat(simple / 10.06)))
                }
                line(flat, muted, dash: [4, 4]); line(pts, up, width: 3)
                label("Compounding at 8%: about 10× in 30 years", at: CGPoint(x: w * 0.06, y: h * 0.08), up)
                label("Without compounding: 3.4×", at: CGPoint(x: w * 0.94, y: h * 0.62), muted, anchor: .trailing)
            case "diversification":
                for i in 0..<20 {
                    let x = w * 0.08 + CGFloat(i % 10) * w * 0.085, y = h * (0.3 + CGFloat(i / 10) * 0.3)
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 16, height: 16)), with: .color(i == 7 ? down : up.opacity(0.75)))
                }
                label("One company falls, the other 19 cushion it", at: CGPoint(x: w * 0.06, y: h * 0.12), ink)
            case "short":
                line(zigzag([0.3, 0.25, 0.4, 0.5, 0.45, 0.65, 0.75]), down)
                label("Sell borrowed shares high", at: CGPoint(x: w * 0.06, y: h * 0.15), ink)
                label("Buy back lower = profit", at: CGPoint(x: w * 0.94, y: h * 0.88), up, anchor: .trailing)
                label("But if it rises, losses have no limit", at: CGPoint(x: w * 0.06, y: h * 0.97), down)
            case "margin":
                context.fill(Path(CGRect(x: w * 0.15, y: h * 0.2, width: w * 0.25, height: h * 0.6)), with: .color(accent))
                context.fill(Path(CGRect(x: w * 0.4, y: h * 0.2, width: w * 0.25, height: h * 0.6)), with: .color(muted.opacity(0.4)))
                label("Your $10k", at: CGPoint(x: w * 0.275, y: h * 0.5), .white, anchor: .center)
                label("Borrowed $10k", at: CGPoint(x: w * 0.525, y: h * 0.5), ink, anchor: .center)
                label("10% drop → you lose 20%", at: CGPoint(x: w * 0.15, y: h * 0.92), down)
            case "pumpDump":
                line(zigzag([0.85, 0.84, 0.86, 0.6, 0.25, 0.1, 0.5, 0.82, 0.88]), down)
                label("Hype: \"10× by Friday!\"", at: CGPoint(x: w * 0.3, y: h * 0.12), ink)
                label("Insiders sell", at: CGPoint(x: w * 0.6, y: h * 0.1), down)
                label("Late buyers left holding losses", at: CGPoint(x: w * 0.94, y: h * 0.97), down, anchor: .trailing)
            default:
                line(zigzag([0.6, 0.5, 0.55, 0.4, 0.45, 0.3]), accent)
            }
        }
        .accessibilityHidden(true)
    }
}
