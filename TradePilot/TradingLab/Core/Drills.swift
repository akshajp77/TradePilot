import Foundation

/// Chart-reading drills. Each one shows real bars up to a point and asks a question with an
/// objective answer, so learners practice reading charts rather than guessing the future.
nonisolated enum DrillKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case trend, stop, volume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trend: return "Spot the trend"
        case .stop: return "Place the stop loss"
        case .volume: return "Read the volume"
        }
    }
    var prompt: String {
        switch self {
        case .trend: return "Over these bars, is the price mostly going up, going down, or moving sideways?"
        case .stop: return "Imagine you just bought at the last price. Tap where you'd put your stop loss."
        case .volume: return "Look at the last bar's volume (the bars at the bottom). Compared with normal, is it high, normal, or low?"
        }
    }
    var options: [String] {
        switch self {
        case .trend: return ["Up", "Sideways", "Down"]
        case .volume: return ["High", "Normal", "Low"]
        case .stop: return []
        }
    }
}

nonisolated struct Drill: Sendable, Identifiable {
    let id = UUID()
    let kind: DrillKind
    let symbol: String
    let bars: [Bar]
    /// Index into `options` for multiple-choice drills.
    let answer: Int?
    /// For stop drills: a sensible stop zone (below the recent low, not too far).
    let stopZone: ClosedRange<Double>?
    let explanation: String
}

nonisolated enum DrillGrader {
    struct Result: Sendable { let correct: Bool; let message: String }

    static func grade(_ drill: Drill, choice: Int? = nil, stopPrice: Double? = nil) -> Result {
        switch drill.kind {
        case .stop:
            guard let price = stopPrice, let zone = drill.stopZone, let last = drill.bars.last?.close else {
                return Result(correct: false, message: "Tap a price on the chart.")
            }
            if price >= last { return Result(correct: false, message: "For a buy, the stop goes below the current price. Above it, you'd be stopped out instantly.") }
            if price > zone.upperBound { return Result(correct: false, message: "Too tight. Normal wiggles would knock you out. " + drill.explanation) }
            if price < zone.lowerBound { return Result(correct: false, message: "Too far. You'd lose a lot before admitting you were wrong. " + drill.explanation) }
            return Result(correct: true, message: "Nice. " + drill.explanation)
        default:
            guard let choice, let answer = drill.answer else { return Result(correct: false, message: "Pick an answer.") }
            return Result(correct: choice == answer, message: drill.explanation)
        }
    }
}

nonisolated enum DrillFactory {
    /// Builds a drill from a long run of bars. Returns nil if the bars don't fit the question
    /// (for example, an ambiguous trend), so the caller can try another window.
    static func make(_ kind: DrillKind, symbol: String, bars: [Bar], rng: inout SplitMix64) -> Drill? {
        let window = 60
        guard bars.count > window + 30 else { return nil }
        for _ in 0..<12 {
            let end = Int.random(in: (window + 20)..<bars.count, using: &rng)
            let slice = Array(bars[(end - window)..<end])
            if let drill = build(kind, symbol: symbol, slice: slice, context: Array(bars[max(0, end - window - 20)..<end])) { return drill }
        }
        return nil
    }

    static func build(_ kind: DrillKind, symbol: String, slice: [Bar], context: [Bar]) -> Drill? {
        let closes = slice.map(\.close)
        guard let first = closes.first, let last = closes.last, first > 0 else { return nil }
        let atr = Indicators.atr(context).last.flatMap { $0 } ?? (slice.map(\.range).reduce(0, +) / Double(slice.count))
        guard atr > 0 else { return nil }
        switch kind {
        case .trend:
            // Linear-regression slope over the window, in ATRs per window.
            let n = Double(closes.count)
            let xs = (0..<closes.count).map(Double.init)
            let mx = xs.reduce(0, +) / n, my = closes.reduce(0, +) / n
            let slope = zip(xs, closes).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let move = slope * n / atr
            let answer: Int
            let text: String
            if move > 4 { answer = 0; text = "Up. The price made higher highs and higher lows, and ended well above where it started." }
            else if move < -4 { answer = 2; text = "Down. The price made lower highs and lower lows, and ended well below where it started." }
            else if abs(move) < 1.5 { answer = 1; text = "Sideways. The price bounced up and down in a range without really going anywhere." }
            else { return nil }   // ambiguous; skip
            return Drill(kind: .trend, symbol: symbol, bars: slice, answer: answer, stopZone: nil, explanation: text)
        case .stop:
            let recentLow = slice.suffix(10).map(\.low).min() ?? last
            let upper = min(last - 0.5 * atr, recentLow)
            let lower = max(recentLow - 1.5 * atr, last - 3 * atr)
            guard upper > lower, lower > 0 else { return nil }
            let text = "A good spot is just under the recent low (around \(Format.price(recentLow))), which is where the idea is clearly wrong, and within about 2–3 times the normal bar size (\(Format.price(atr)))."
            return Drill(kind: .stop, symbol: symbol, bars: slice, answer: nil, stopZone: lower...upper, explanation: text)
        case .volume:
            let volumes = slice.dropLast().suffix(20).map(\.volume)
            guard volumes.count >= 10, let lastVolume = slice.last?.volume else { return nil }
            let average = volumes.reduce(0, +) / Double(volumes.count)
            guard average > 0 else { return nil }
            let ratio = lastVolume / average
            let answer: Int
            if ratio >= 1.8 { answer = 0 } else if ratio <= 0.55 { answer = 2 } else if ratio > 0.8 && ratio < 1.25 { answer = 1 } else { return nil }
            let text = "The last bar traded \(String(format: "%.1f", ratio))× the average of the 20 bars before it. " +
                (answer == 0 ? "High volume means lots of people cared about that move, so it's more meaningful."
                 : answer == 2 ? "Low volume means few people took part, so the move is less convincing."
                 : "That's about normal, so the move isn't unusual either way.")
            return Drill(kind: .volume, symbol: symbol, bars: slice, answer: answer, stopZone: nil, explanation: text)
        }
    }
}
