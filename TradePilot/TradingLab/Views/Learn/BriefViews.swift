import SwiftUI

// MARK: - Daily market brief

struct MarketBriefView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @EnvironmentObject private var news: NewsStore
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData

    private static let indexes: [(String, String)] = [("SPY", "S&P 500 (500 big US companies)"), ("QQQ", "Nasdaq 100 (big tech-heavy)"), ("DIA", "Dow Jones (30 giants)"), ("IWM", "Russell 2000 (small companies)")]
    private static let sectors: [(String, String)] = [("XLK", "Technology"), ("XLC", "Communication"), ("XLY", "Shopping & cars"), ("XLF", "Banks & finance"),
                                                     ("XLV", "Health care"), ("XLI", "Industrial"), ("XLE", "Energy"), ("XLP", "Everyday goods"),
                                                     ("XLU", "Utilities"), ("XLB", "Materials"), ("XLRE", "Real estate")]

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Market brief").font(theme.page)
                    MarketStatusLine(market: market)
                }
                Text(summary).font(theme.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.s8) {
                    HStack { Text("The big picture").font(theme.section); ExplainButton(term: "Index fund") }
                    ForEach(Self.indexes, id: \.0) { symbol, name in row(symbol, name) }
                }
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Which parts of the market moved").font(theme.section)
                    Text("Each sector is a fund holding companies of one kind. Comparing them shows what investors favored today.").font(theme.meta).foregroundStyle(theme.muted)
                    let sorted = Self.sectors.sorted { (market.change($0.0) ?? 0) > (market.change($1.0) ?? 0) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(sorted, id: \.0) { symbol, name in
                            let change = market.change(symbol)
                            VStack(spacing: 2) {
                                Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                Text(change.map { Format.percent($0 / 100, digits: 1) } ?? "—").font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(change == nil ? theme.muted : .white)
                            .background((change.map { theme.movement($0 >= 0).opacity(min(1, 0.35 + abs($0) / 3)) } ?? theme.surface), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Coming up").font(theme.section)
                    let upcoming = Curriculum.calendar.filter { ($0.day ?? .distantPast) >= market.hours.dayStart(Date()) }.prefix(4)
                    if upcoming.isEmpty { Text("No major scheduled releases in the calendar.").foregroundStyle(theme.muted) }
                    ForEach(Array(upcoming)) { item in CalendarRow(item: item) }
                    Text("Dates from the Federal Reserve and the Bureau of Labor Statistics. Fed dates for 2027 are tentative.").font(theme.meta).foregroundStyle(theme.muted)
                }
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Headlines").font(theme.section)
                    let feed = news.feed(["SPY"])
                    if feed.articles.isEmpty { Text(feed.loading ? "Loading…" : "No headlines right now.").foregroundStyle(theme.muted) }
                    ForEach(feed.articles.prefix(5)) { article in NewsArticleRow(article: article, focusSymbol: "SPY") }
                }
            }
        }
        .learningTheme()
        .navigationTitle("Market brief").appInlineTitle()
        .task {
            await market.loadDelayed((Self.indexes + Self.sectors).map(\.0).filter { market.price($0) == nil || market.change($0) == nil })
            await news.load(["SPY"])
        }
    }

    /// One plain-English paragraph built from today's numbers.
    private var summary: String {
        guard let spy = market.change("SPY") else { return "Loading today's numbers…" }
        let direction = abs(spy) < 0.25 ? "barely moved" : spy > 0 ? "rose \(Format.percent(spy / 100, digits: 1).dropFirst())" : "fell \(Format.percent(-spy / 100, digits: 1).dropFirst())"
        var text = "The S&P 500 \(direction) \(market.hours.isOpen(at: Date()) ? "so far today" : "in the last session")."
        let sectorMoves = Self.sectors.compactMap { s in market.change(s.0).map { (s.1, $0) } }
        if let best = sectorMoves.max(by: { $0.1 < $1.1 }), let worst = sectorMoves.min(by: { $0.1 < $1.1 }), best.1 - worst.1 > 0.5 {
            text += " \(best.0) led (\(Format.percent(best.1 / 100, digits: 1))) while \(worst.0.lowercased()) lagged (\(Format.percent(worst.1 / 100, digits: 1)))."
        }
        if let small = market.change("IWM"), abs(small - spy) > 0.75 {
            text += small > spy ? " Smaller companies did better than big ones, often a sign investors are feeling confident." : " Smaller companies did worse than big ones, often a sign investors are being careful."
        }
        if abs(spy) >= 2 { text += " A move this size is unusual: most days the S&P 500 moves less than 1%." }
        return text
    }

    private func row(_ symbol: String, _ name: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol).font(theme.label).holdToExplainSymbol(symbol)
                Text(name).font(theme.meta).foregroundStyle(theme.muted)
            }
            Spacer()
            Text(market.price(symbol).map(Format.price) ?? "—").font(theme.label.monospacedDigit())
            Text(market.change(symbol).map { Format.percent($0 / 100) } ?? "—").font(theme.label.monospacedDigit())
                .foregroundStyle(theme.movement((market.change(symbol) ?? 0) >= 0)).frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

struct CalendarRow: View {
    @Environment(\.theme) private var theme
    let item: EconomicEvent
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(item.explanation).font(theme.meta).foregroundStyle(theme.muted).padding(.vertical, 4)
        } label: {
            HStack {
                Text(item.day?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? item.date).font(theme.label.monospacedDigit()).frame(width: 100, alignment: .leading)
                Text(item.title).font(theme.label)
            }
        }
    }
}

// MARK: - Historical event replays

struct EventListView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Famous market days").font(theme.page)
                Text("Relive real market events one day at a time, make decisions as they happen, and see how your choices compare with simply holding.")
                    .foregroundStyle(theme.muted)
                ForEach(Curriculum.events) { event in
                    NavigationLink { EventReplayView(store: store, event: event) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(theme.section)
                            Text("\(event.symbol) · \(event.subtitle)").font(theme.meta).foregroundStyle(theme.muted)
                            if let last = store.learning.eventReplays.first(where: { $0.eventID == event.id }) {
                                Text("Last time: \(Format.money(last.endingValue)) vs \(Format.money(last.holdValue)) by holding").font(theme.meta).foregroundStyle(theme.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                    }.buttonStyle(.plain)
                }
            }
        }
        .learningTheme()
        .navigationTitle("Market history").appInlineTitle()
    }
}

struct EventReplayView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    let event: HistoricalEvent
    @State private var bars: [Bar] = []
    @State private var revealed = 0
    @State private var loading = true
    @State private var shares = 0.0
    @State private var cash = 0.0
    @State private var putIn = 1_000.0
    @State private var pending: HistoricalEvent.Beat?
    @State private var choices: [String: String] = [:]
    @State private var shownBeats: [HistoricalEvent.Beat] = []
    @State private var finished = false
    @State private var tool: DrawingTool?

    private var startIndex: Int {
        guard let start = EconomicEvent.parse(event.start) else { return 0 }
        return bars.firstIndex { $0.time >= start } ?? 0
    }
    private var currentClose: Double { revealed > 0 && revealed <= bars.count ? bars[revealed - 1].close : 0 }
    private var value: Double { cash + shares * currentClose }
    private var holdValue: Double {
        guard bars.indices.contains(startIndex), bars[startIndex].close > 0 else { return 1_000 }
        return 1_000 / bars[startIndex].close * currentClose
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text(event.title).font(theme.page)
                Text(event.subtitle).font(theme.meta).foregroundStyle(theme.muted)
                if loading {
                    ProgressView("Loading history…").frame(maxWidth: .infinity, minHeight: 260)
                } else if bars.isEmpty {
                    Text("Couldn't load the price history for \(event.symbol). Check your connection.").foregroundStyle(theme.muted)
                } else {
                    if revealed <= startIndex { Text(event.intro).fixedSize(horizontal: false, vertical: true) }
                    ProChartView(data: .build(bars: Array(bars.prefix(revealed)), timeframe: .d1, preferences: ChartPreferences(), previousClose: nil, hours: store.market.hours),
                                 style: .candles, showVolume: true, resetKey: "event-\(event.id)", tool: $tool)
                        .frame(height: 260)
                    scoreboard
                    if let beat = pending {
                        decisionCard(beat)
                    } else if finished {
                        ending
                    } else {
                        HStack(spacing: Space.s12) {
                            ActionButton(title: revealed <= startIndex ? "Start" : "Next day") { advance(1) }
                            ActionButton(title: "Skip 5 days", secondary: true) { advance(5) }
                        }
                    }
                    ForEach(shownBeats.reversed(), id: \.date) { beat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(EconomicEvent.parse(beat.date)?.formatted(date: .abbreviated, time: .omitted) ?? beat.date).font(theme.meta).foregroundStyle(theme.muted)
                            Text(beat.text).fixedSize(horizontal: false, vertical: true)
                            if let choice = choices[beat.date] { Text("You chose: \(choice)").font(theme.meta).foregroundStyle(theme.accent) }
                        }
                        .padding(Space.s12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                    }
                }
            }
            .padding(Space.s16)
            .animation(.easeInOut(duration: 0.3), value: shownBeats.count)
        }
        .background(theme.paper)
        .learningTheme()
        .navigationTitle(event.symbol).appInlineTitle()
        .task { await load() }
    }

    private var scoreboard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your $\(Int(putIn))").font(theme.meta).foregroundStyle(theme.muted)
                Text(Format.money(value)).font(theme.section.monospacedDigit())
                    .holdToExplain("Your money", value: Format.money(value), context: ["What $\(Int(putIn)) became in this replay."], practice: false)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("If you'd just held $1,000").font(theme.meta).foregroundStyle(theme.muted)
                Text(Format.money(holdValue)).font(theme.section.monospacedDigit()).foregroundStyle(theme.muted)
                    .holdToExplain("If you'd just held", value: Format.money(holdValue), practice: false)
            }
        }
        .opacity(revealed > startIndex ? 1 : 0.4)
    }

    private func decisionCard(_ beat: HistoricalEvent.Beat) -> some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text(beat.text).font(theme.label).fixedSize(horizontal: false, vertical: true)
            Text(beat.decision ?? "What do you do?").font(theme.section)
            ActionButton(title: "Hold what I have") { decide(beat, "Hold") }
            ActionButton(title: shares > 0 ? "Sell everything" : "Stay out", secondary: true) { decide(beat, shares > 0 ? "Sell" : "Stay out") }
            ActionButton(title: cash > 0 && shares == 0 ? "Buy back in" : "Add $500 more", secondary: true) { decide(beat, cash > 0 && shares == 0 ? "Buy back in" : "Add $500") }
        }
        .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        .transition(.opacity)
    }

    private var ending: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("How it ended").font(theme.section)
            let diff = value - holdValue * (putIn / 1_000)
            Text("You put in \(Format.money(putIn)) and ended with \(Format.money(value)). Holding the whole time would have turned the same money into \(Format.money(holdValue * putIn / 1_000)), \(diff >= 0 ? "\(Format.money(diff)) less than your choices" : "\(Format.money(-diff)) more than your choices").")
                .fixedSize(horizontal: false, vertical: true)
            Text(event.lesson).font(theme.label).fixedSize(horizontal: false, vertical: true)
            Text("Remember: you knew this was a famous event. In real time, nobody knows which drops recover quickly and which keep going.").font(theme.meta).foregroundStyle(theme.muted)
            ActionButton(title: "Replay from the start", secondary: true) { restart() }
        }
        .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
    }

    private func load() async {
        guard bars.isEmpty, let start = EconomicEvent.parse(event.start), let end = EconomicEvent.parse(event.end) else { return }
        loading = true
        bars = await Feeds.yahooBars(event.symbol, from: start.addingTimeInterval(-45 * 86_400), to: end.addingTimeInterval(2 * 86_400)) ?? []
        loading = false
        restart()
    }

    private func restart() {
        revealed = startIndex
        shares = 0; cash = 0; putIn = 1_000
        choices = [:]; shownBeats = []; pending = nil; finished = false
    }

    private func advance(_ days: Int) {
        guard let end = EconomicEvent.parse(event.end) else { return }
        if revealed <= startIndex {
            revealed = startIndex + 1
            if bars.indices.contains(startIndex) { shares = 1_000 / bars[startIndex].close }
            return
        }
        for _ in 0..<days {
            guard revealed < bars.count, bars[revealed].time <= end.addingTimeInterval(86_399) else { break }
            revealed += 1
            let day = bars[revealed - 1].time
            for beat in event.beats where !shownBeats.contains(where: { $0.date == beat.date }) {
                if let date = EconomicEvent.parse(beat.date), date <= day {
                    shownBeats.append(beat)
                    if beat.decision != nil { pending = beat; return }
                }
            }
        }
        let last = revealed >= bars.count || bars[revealed].time > end.addingTimeInterval(86_399)
        if last && pending == nil {
            finished = true
            store.saveEventReplay(EventReplayRecord(eventID: event.id, choices: choices, endingValue: value, holdValue: holdValue * putIn / 1_000))
        }
    }

    private func decide(_ beat: HistoricalEvent.Beat, _ choice: String) {
        choices[beat.date] = choice
        let price = currentClose
        switch choice {
        case "Sell": cash += shares * price; shares = 0
        case "Buy back in": shares += cash / price; cash = 0
        case "Add $500": shares += 500 / price; putIn += 500
        default: break
        }
        pending = nil
    }
}

// MARK: - AI tutor

struct TutorView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    @StateObject private var tutor = TutorModel()
    @State private var draft = ""
    private let starters = ["What's a stop loss, and where should mine go?", "Why did my last trade lose money?", "How do I know if a stock is in an uptrend?",
                            "What should I practice next?", "Explain the chart I'm looking at", "Is day trading a good idea for me?"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s12) {
                        if tutor.messages.isEmpty {
                            Text("Ask anything about stocks, charts or your practice trades. The tutor explains and teaches; it won't tell you what to buy or sell.")
                                .foregroundStyle(theme.muted)
                            ForEach(starters, id: \.self) { starter in
                                Button { send(starter) } label: {
                                    Text(starter).font(theme.label).multilineTextAlignment(.leading).padding(Space.s12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                                }.buttonStyle(.plain)
                            }
                        }
                        ForEach(tutor.messages) { message in
                            HStack {
                                if message.fromUser { Spacer(minLength: 40) }
                                Text(LocalizedStringKey(message.text)).font(theme.body).textSelection(.enabled)
                                    .padding(Space.s12)
                                    .foregroundStyle(message.fromUser ? .white : theme.ink)
                                    .background(message.fromUser ? theme.accent : theme.surface, in: RoundedRectangle(cornerRadius: 14))
                                if !message.fromUser { Spacer(minLength: 40) }
                            }
                            .id(message.id)
                        }
                        if tutor.thinking { ProgressView().padding(.leading, Space.s12) }
                    }
                    .padding(Space.s16)
                }
                .onChange(of: tutor.messages.count) { _, _ in
                    if let last = tutor.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Rule()
            HStack(spacing: Space.s8) {
                TextField("Ask a question", text: $draft, axis: .vertical).lineLimit(1...4).inputField()
                    .onSubmit { send(draft) }
                Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || tutor.thinking)
                    .accessibilityLabel("Send")
            }
            .padding(Space.s12)
        }
        .background(theme.paper)
        .learningTheme()
        .navigationTitle("Tutor").appInlineTitle()
        .toolbar { if !tutor.messages.isEmpty { ToolbarItem { Button("New chat") { tutor.reset() } } } }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        let context = store.tutorContext()
        Task { await tutor.ask(question, context: context) }
    }
}

// MARK: - Weekly report card and trade reviews

struct WeeklyReportView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore

    var body: some View {
        let report = store.weeklyReport
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Last 7 days")
                    Text("Report card").font(theme.page)
                }
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("This week's one fix").font(theme.section)
                    Text(report.fix).font(theme.body).fixedSize(horizontal: false, vertical: true)
                    if let praise = report.praise { Label(praise, systemImage: "hand.thumbsup.fill").font(theme.label).foregroundStyle(theme.accent) }
                }
                .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Space.s16) {
                    cell("Trades closed", "\(report.trades)")
                    cell("Result", Format.signedMoney(report.netPnL), color: theme.gain(report.netPnL >= 0))
                    cell("Won", report.winRate.map { "\(Int($0 * 100))%" } ?? "—", term: "Win rate")
                    cell("Had a stop loss", report.stopUsage.map { "\(Int($0 * 100))%" } ?? "—", term: "Stop loss")
                    cell("Average trade grade", report.averageScore.map { TradeReview.grade($0) } ?? "—")
                    cell("Good-habit streak", "\(report.processStreak) \(report.processStreak == 1 ? "day" : "days")")
                }
                if let best = report.bestSetup { Text("Best setup: \(best.name) (\(Format.signedMoney(best.pnl)))").font(theme.label) }
                if let worst = report.worstSetup { Text("Toughest setup: \(worst.name) (\(Format.signedMoney(worst.pnl)))").font(theme.label) }
                if let hour = report.worstHour { Text("Toughest hour: \(hour.hour):00 ET (\(Format.signedMoney(hour.pnl)))").font(theme.label) }
                Text("The streak counts days in a row where every trade had a stop loss and got a C or better. It rewards habits, not luck.")
                    .font(theme.meta).foregroundStyle(theme.muted)
                if let last = store.lastReview {
                    NavigationLink { TradeDetailView(store: store, trip: last.trip) } label: {
                        TradeReviewCard(trip: last.trip, review: last.review)
                    }.buttonStyle(.plain)
                }
                NavigationLink("All trades and stats →") { JournalAnalyticsView(store: store) }.font(theme.label)
            }
        }
        .learningTheme()
        .navigationTitle("Report card").appInlineTitle()
    }

    private func cell(_ title: String, _ value: String, color: Color? = nil, term: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) { Text(title).font(theme.meta).foregroundStyle(theme.muted); if let term { ExplainButton(term: term, size: 11) } }
            Text(value).font(theme.section.monospacedDigit()).foregroundStyle(color ?? theme.ink)
        }
    }
}

/// Grade and checklist for one closed trade.
struct TradeReviewCard: View {
    @Environment(\.theme) private var theme
    let trip: RoundTrip
    let review: TradeReview
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            HStack(alignment: .center, spacing: Space.s12) {
                Text(review.grade).font(.system(size: 30, weight: .bold, design: .rounded))
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.white)
                    .background(gradeColor, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Grade \(review.grade)")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(trip.isLong ? "Bought" : "Shorted") \(trip.symbol) · \(Format.signedMoney(trip.netPnL))").font(theme.label)
                    Text(review.headline).font(theme.meta).foregroundStyle(theme.muted).lineLimit(compact ? 2 : nil)
                }
            }
            if !compact {
                ForEach(review.items, id: \.self) { item in
                    Label(item.text, systemImage: item.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(theme.meta).foregroundStyle(item.passed ? theme.ink : theme.loss)
                }
            }
        }
        .padding(Space.s16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
    }

    private var gradeColor: Color {
        switch review.grade { case "A", "B": return theme.stockGain; case "C": return theme.warning; default: return theme.stockLoss }
    }
}
