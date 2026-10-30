import SwiftUI

// Hold any number, ticker or term: everything else blurs and two cards appear,
// the value itself on top and what it means (with live context) underneath.
// Tap anywhere to close.

/// Something the user held to have explained.
struct ExplainItem: Identifiable, Equatable {
    let id = UUID()
    /// What the value is ("Buying power", "Last price"). For a ticker, the ticker itself.
    var title: String
    /// The value exactly as shown ("$12,430.22"). Empty for a ticker.
    var value: String
    /// Glossary term to explain with. Defaults to a lookup from the title.
    var term: String? = nil
    /// The stock this value belongs to, for live context.
    var symbol: String? = nil
    /// Extra context from the screen that showed the value.
    var context: [String] = []
    /// Colour for the value (gains green, losses red).
    var tone: Color? = nil
    /// False when the value isn't about the practice account (Alpaca, replays), so its numbers aren't added as context.
    var practiceContext = true

    var isTicker: Bool { value.isEmpty && symbol != nil && symbol == title }
    static func == (a: ExplainItem, b: ExplainItem) -> Bool { a.id == b.id }
}

@MainActor
final class ExplainCenter: ObservableObject {
    @Published private(set) var item: ExplainItem?
    func show(_ item: ExplainItem) { self.item = item }
    func dismiss() { withAnimation(.easeOut(duration: 0.18)) { item = nil } }
}

private struct ExplainCenterKey: EnvironmentKey { static let defaultValue: ExplainCenter? = nil }
extension EnvironmentValues {
    var explainCenter: ExplainCenter? {
        get { self[ExplainCenterKey.self] }
        set { self[ExplainCenterKey.self] = newValue }
    }
}

extension View {
    /// Hold to explain a number or label. `value` is the text exactly as the screen shows it.
    func holdToExplain(_ title: String, value: String, term: String? = nil, symbol: String? = nil,
                       context: [String] = [], tone: Color? = nil, practice: Bool = true) -> some View {
        modifier(HoldToExplain { ExplainItem(title: title, value: value, term: term, symbol: symbol, context: context,
                                             tone: tone, practiceContext: practice) })
    }

    /// Hold a ticker to explain the company and your position in it.
    func holdToExplainSymbol(_ symbol: String) -> some View {
        modifier(HoldToExplain { ExplainItem(title: symbol, value: "", symbol: symbol) })
    }

    /// Draws the blur and the cards for every hold inside this view. Put one at the app root and one in each sheet.
    func explainHost(store: LabStore?) -> some View { modifier(ExplainHost(store: store)) }
}

@MainActor
private struct HoldToExplain: ViewModifier {
    @Environment(\.explainCenter) private var center
    let make: () -> ExplainItem

    func body(content: Content) -> some View {
        if let center {
            content
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.35, perform: { center.show(make()) })
                .accessibilityAction(named: Text("Explain")) { center.show(make()) }
        } else {
            content
        }
    }
}

@MainActor
private struct ExplainHost: ViewModifier {
    @StateObject private var center = ExplainCenter()
    let store: LabStore?

    func body(content: Content) -> some View {
        let active = center.item != nil
        content
            .environment(\.explainCenter, center)
            .blur(radius: active ? 16 : 0)
            .allowsHitTesting(!active)
            .accessibilityHidden(active)
            .animation(.easeOut(duration: 0.22), value: active)
            .overlay {
                if let item = center.item {
                    ExplainCards(item: item, details: ExplainLibrary.details(for: item, store: store)) { center.dismiss() }
                        .id(item.id)
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: center.item?.id)
    }
}

// MARK: - The two cards

private struct ExplainCards: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: ExplainItem
    let details: ExplainDetails
    let close: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.28 : 0).ignoresSafeArea()
            VStack(spacing: Space.s12) {
                valueCard
                    .scaleEffect(shown || reduceMotion ? 1 : 0.88)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.38, dampingFraction: 0.78), value: shown)
                explanationCard
                    .scaleEffect(shown || reduceMotion ? 1 : 0.94)
                    .offset(y: shown || reduceMotion ? 0 : 28)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.42, dampingFraction: 0.82).delay(reduceMotion ? 0 : 0.07), value: shown)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, Space.s24)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
    }

    private var valueCard: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Eyebrow(text: details.heading)
            Text(details.value)
                .font(theme.display).monospacedDigit()
                .foregroundStyle(item.tone ?? theme.ink)
                .lineLimit(2).minimumScaleFactor(0.45)
            if let subtitle = details.subtitle {
                Text(subtitle).font(theme.meta).foregroundStyle(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s24)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.line))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    private var explanationCard: some View {
        ViewThatFits(in: .vertical) {
            explanationBody
            ScrollView { explanationBody }.frame(maxHeight: 420)
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.line))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
    }

    private var explanationBody: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("What it means").font(theme.label)
            Text(details.explanation).font(theme.body).fixedSize(horizontal: false, vertical: true)
            if let example = details.example {
                Text(example).font(theme.meta).italic().foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !details.context.isEmpty {
                Rule()
                Text("Right now").font(theme.label)
                ForEach(Array(details.context.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                        Circle().fill(theme.accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(line).font(theme.meta).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let lesson = details.lesson {
                Label("Learn more in the lesson “\(lesson)”", systemImage: "book.closed").font(theme.meta).foregroundStyle(theme.accent)
            }
            Text("Tap anywhere to close").font(.system(size: 11)).foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s24)
    }
}

// MARK: - What to say

struct ExplainDetails {
    var heading: String
    var value: String
    var subtitle: String? = nil
    var explanation: String
    var example: String? = nil
    var context: [String] = []
    var lesson: String? = nil
}

@MainActor
enum ExplainLibrary {
    /// Labels used on screens that mean the same thing as a glossary term.
    static let aliases: [String: String] = [
        "portfolio value": "Equity", "account value": "Equity", "virtual cash": "Cash",
        "today's profit or loss": "P&L", "today": "P&L", "net p&l": "P&L", "profit or loss": "P&L",
        "locked in": "Realized return", "on paper": "Unrealized return", "unrealized": "Unrealized return",
        "buying power at alpaca": "Buying power", "money available to trade": "Buying power",
        "margin loan": "Margin", "maintenance requirement": "Maintenance margin", "margin you must keep": "Maintenance margin",
        "limit price": "Limit order", "stop price": "Stop loss", "virtual fill": "Fill", "fill price": "Fill",
        "maximum recorded drawdown": "Drawdown", "share of your account": "Position sizing",
        "you'd lose if the stop hits": "Risk", "that's at most": "Risk", "rvol": "Relative volume",
        "bid price": "Bid", "ask price": "Ask",
    ]

    /// Plain-language notes for values that aren't glossary terms.
    static let notes: [String: String] = [
        "price": "The price of the most recent trade: what someone just paid for one share. It changes every time a new trade happens.",
        "last": "The price of the most recent trade: what someone just paid for one share. It changes every time a new trade happens.",
        "last price": "The price of the most recent trade: what someone just paid for one share. It changes every time a new trade happens.",
        "change": "How much the price has moved since the reference point (usually yesterday's closing price). Green means up, red means down.",
        "change today": "How much the price has moved since yesterday's closing price. Green means up, red means down.",
        "move": "How much the price moved over the period you're looking at, in dollars and as a percent.",
        "shares": "How many shares this is. Each share is one small piece of ownership in the company.",
        "order type": "How the order is told to buy or sell: right away at the market price, or only at a price you choose.",
        "order value": "Roughly how much money this order moves: shares × price. It is the size of the trade, not how much you could lose.",
        "commission": "The fee your broker charges for the trade. Many brokers charge $0 for stocks; this lab lets you practise with a fee so you see how costs add up.",
        "average winning sale": "On average, how much you made on sales that closed with a profit.",
        "average losing sale": "On average, how much you lost on sales that closed with a loss. Compare it with your average win: big losses can erase many small wins.",
        "reserved for working orders": "Money set aside for orders that haven't filled yet, so you can't spend it twice.",
        "filled orders": "How many of your orders actually went through (filled), as opposed to being cancelled or still waiting.",
        "filled": "When the order went through.",
        "role": "What this order is for: opening the trade, or protecting it (a stop loss or profit target attached to it).",
        "hypothetical portfolio": "What your portfolio would be worth if the scenario you entered happened.",
        "change in value": "How much your portfolio's value would rise or fall in this scenario.",
        "your portfolio": "How much your practice portfolio returned over the same period.",
        "spy price return": "How much the S&P 500 (through the SPY fund) returned over the same period. It's the yardstick: beating it is hard, even for professionals.",
        "amount": "How much money goes in each time.",
        "your money": "What the money you put in is worth now in this replay.",
        "if you'd just held": "What $1,000 would be worth if you'd bought at the start and never traded. It's the yardstick for whether trading helped.",
        "day trades (5 days)": "How many day trades (buying and selling the same stock on the same day) you've made in the last five business days.",
        "print": "One trade that just happened: the price and how many shares changed hands.",
        "account type": "Whether this practice account is a cash account (you can only spend money you have) or a margin account (you can borrow), and which day-trading rule applies.",
        "next purchase": "When the next automatic purchase is scheduled.",
        "now": "The current price and how much it has moved today.",
        "sync": "Whether this device's practice data is saved to your account and shared with your other devices.",
        "volume": "How many shares have traded today. High volume means lots of people are buying and selling, so it's usually easier to get in and out.",
        "invest each month": "The amount you'd add every month. Regular investing like this is called dollar-cost averaging.",
        "size of each trade": "How much money goes into each trade in this simulation.",
        "cash": "Money in the account that isn't invested in anything right now.",
        "net return": "Your total profit or loss after all trades and fees.",
        "real-money trading": "Whether a real brokerage account is connected, and whether it's a paper (pretend) or live (real money) account.",
        "connected with": "How this app is connected to your Alpaca account.",
        "account": "Which Alpaca account is connected: paper (pretend money) or live (real money).",
        "position": "What you currently hold in this stock: long means you own shares; short means you borrowed and sold them, hoping to buy back cheaper.",
        "quantity": "How many shares to buy or sell.",
        "trade size": "How many shares this trade was for.",
        "high": "The highest price it traded at during the period.",
        "low": "The lowest price it traded at during the period.",
        "open": "The first price it traded at when the period began.",
        "close": "The last price it traded at when the period ended.",
    ]

    /// Values about the whole account get a snapshot of the account as context.
    static let accountTerms: Set<String> = ["Equity", "Cash", "Buying power", "P&L", "Margin", "Maintenance margin",
                                            "Realized return", "Unrealized return", "Drawdown", "Risk", "Position sizing"]

    static func details(for item: ExplainItem, store: LabStore?) -> ExplainDetails {
        if item.isTicker, let symbol = item.symbol { return ticker(symbol, store: store, extra: item.context) }

        let key = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Curriculum.term(item.term ?? aliases[key] ?? item.title)
        let explanation = notes[key] ?? entry?.explanation
            ?? "This is the \(item.title.lowercased()) shown on this screen."
        var context = item.context
        if item.practiceContext, let symbol = item.symbol, let store { context += symbolContext(symbol, store: store) }
        if item.practiceContext, let entry, accountTerms.contains(entry.term), item.symbol == nil, let store { context += accountContext(store) }

        var subtitle: String? = nil
        if let symbol = item.symbol { subtitle = store?.security(symbol)?.name ?? symbol }
        return ExplainDetails(heading: item.title, value: item.value.isEmpty ? "—" : item.value, subtitle: subtitle,
                              explanation: explanation, example: entry?.example,
                              context: unique(context), lesson: entry.flatMap(lessonTitle))
    }

    private static func ticker(_ symbol: String, store: LabStore?, extra: [String]) -> ExplainDetails {
        let security = store?.security(symbol)
        let name = security?.name ?? symbol
        var explanation: String
        switch security?.kind {
        case .etf?: explanation = "\(name) is a fund (an ETF). One share holds a small slice of many investments at once, so it spreads your risk."
        case .index?: explanation = "\(name) is a market index: a scoreboard that tracks a group of stocks. You can't buy it directly, but funds copy it."
        default: explanation = "\(name) is a company you can own a piece of. \(symbol) is its ticker: the short code the market uses for it."
        }
        if let description = security?.description, !description.isEmpty { explanation += "\n\n" + description }
        var context = extra
        if let store { context += symbolContext(symbol, store: store) }
        if let stats = store?.market.statistics[symbol] {
            if let cap = stats.marketCap { context.append("Market cap \("$" + Format.compact(cap)): the total value of all its shares.") }
            if let pe = stats.peRatio, pe > 0 { context.append("Buyers pay about $\(Int(pe.rounded())) for every $1 of yearly profit (P/E \(String(format: "%.1f", pe))).") }
        }
        var subtitle = security.map { [$0.kind.rawValue, $0.sector].filter { !$0.isEmpty }.joined(separator: " · ") }
        if subtitle?.isEmpty == true { subtitle = nil }
        return ExplainDetails(heading: symbol, value: name, subtitle: subtitle, explanation: explanation,
                              example: nil, context: unique(context), lesson: Curriculum.term("Ticker").flatMap(lessonTitle))
    }

    private static func symbolContext(_ symbol: String, store: LabStore) -> [String] {
        var lines: [String] = []
        if let price = store.market.price(symbol) {
            var line = "\(symbol) last traded at \(Format.price(price))"
            if let change = store.market.change(symbol) {
                line += change >= 0 ? ", up \(Format.percent(change / 100)) today" : ", down \(Format.percent(-change / 100)) today"
            }
            lines.append(line + ".")
        }
        if let position = store.position(symbol), position.quantity != 0 {
            let average = position.averagePrice.map { " at \(Format.money($0)) on average" } ?? ""
            lines.append(position.isLong ? "You own \(Format.shares(position.size)) shares\(average)."
                                         : "You're short \(Format.shares(position.size)) shares\(average).")
            if let pnl = store.unrealized(symbol) {
                lines.append(pnl >= 0 ? "You're up \(Format.money(pnl)) on paper (not locked in until you sell)."
                                      : "You're down \(Format.money(-pnl)) on paper (not locked in until you sell).")
            }
            if let value = store.positionValue(symbol), let total = store.portfolioValue, total > 0 {
                lines.append("It's \(Format.percent((value / total).double, digits: 1)) of your portfolio.")
            }
        } else if store.security(symbol)?.kind.tradable != false {
            lines.append("You don't own any \(symbol) in this portfolio.")
        }
        if store.data.watched.contains(symbol) { lines.append("It's on your watchlist.") }
        return lines
    }

    private static func accountContext(_ store: LabStore) -> [String] {
        var lines: [String] = []
        if let value = store.portfolioValue { lines.append("Portfolio value: \(Format.money(value))") }
        lines.append("Cash: \(Format.money(store.cash))")
        lines.append("Buying power: \(Format.money(store.availableBuyingPower))")
        if let day = store.dayPnL { lines.append("Today: \(Format.signedMoney(day))") }
        let held = store.heldSymbols.count
        lines.append(held == 0 ? "No open positions." : "\(held) open position\(held == 1 ? "" : "s").")
        return lines
    }

    private static func lessonTitle(_ entry: GlossaryEntry) -> String? {
        Curriculum.content.pathLessons.first { lesson in lesson.terms.contains { Curriculum.term($0)?.term == entry.term } }?.title
    }

    private static func unique(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

// MARK: - A labeled row you can hold

/// `LabeledContent` that explains itself when held.
struct ExplainRow: View {
    let title: String
    let value: String
    var symbol: String? = nil
    init(_ title: String, value: String, symbol: String? = nil) {
        self.title = title
        self.value = value
        self.symbol = symbol
    }
    var body: some View {
        LabeledContent(title, value: value).holdToExplain(title, value: value, symbol: symbol)
    }
}
