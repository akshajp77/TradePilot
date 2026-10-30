import SwiftUI

struct OrderTicketView: View {
    enum Sizing: String, CaseIterable { case shares = "Shares", dollars = "Dollars", risk = "By risk" }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let context: TicketContext
    let submit: (OrderRequest, TradeNote?) -> Bool

    @State private var side: OrderSide
    @State private var type: OrderType
    @State private var sizing: Sizing = .shares
    @State private var quantity = ""
    @State private var limit = ""
    @State private var stop = ""
    @State private var trail = ""
    @State private var trailInPercent = false
    @State private var tif: TimeInForce = .day
    @State private var extendedHours = false
    @State private var bracket = false
    @State private var takeProfit = ""
    @State private var stopLoss = ""
    @State private var riskPercent: String
    @State private var strategy = "Uncategorized"
    @State private var confidence = 3
    @State private var thesis = ""
    @State private var invalidation = ""
    @State private var horizon = ""
    @State private var confirming = false
    @State private var ignoreCoolDown = false

    init(context: TicketContext, side: OrderSide, type: OrderType = .market, price: Decimal? = nil,
         stopLoss: Decimal? = nil, shares: Decimal? = nil, submit: @escaping (OrderRequest, TradeNote?) -> Bool) {
        self.context = context
        self.submit = submit
        _side = State(initialValue: side)
        _type = State(initialValue: type)
        if let price {
            if type.usesLimit { _limit = State(initialValue: Format.plain(price.tickRounded)) }
            if type.usesStop { _stop = State(initialValue: Format.plain(price.tickRounded)) }
        }
        if let shares { _quantity = State(initialValue: Format.plain(shares)) }
        // Beginners get the stop loss switched on by default.
        let wantsStop = stopLoss != nil || !context.locked.isEmpty || context.live != nil
        if wantsStop { _bracket = State(initialValue: true) }
        if let stopLoss { _stopLoss = State(initialValue: Format.plain(stopLoss.tickRounded)) }
        _riskPercent = State(initialValue: Format.plain(context.account.settings.riskFraction * 100))
        let sessionKind = context.market.hours.sessionKind(at: context.market.now)
        _extendedHours = State(initialValue: type == .limit && (sessionKind == .pre || sessionKind == .post) && !context.locked.contains(.extendedHours))
    }

    // MARK: Derived values

    private var isLive: Bool { context.live != nil }
    private var settings: TradingSettings { context.account.settings }
    private var reference: Decimal? { context.quote?.price }
    private var limitPrice: Decimal? { DecimalInput.positive(limit) }
    private var stopPrice: Decimal? { DecimalInput.positive(stop) }
    private var bid: Decimal? { context.quote.map { isLive ? ($0.bid ?? $0.price) : OrderEngine.bid($0, settings) } }
    private var ask: Decimal? { context.quote.map { isLive ? ($0.ask ?? $0.price) : OrderEngine.ask($0, settings) } }
    private var entryPrice: Decimal? {
        switch type {
        case .limit, .stopLimit: return limitPrice
        case .stop: return stopPrice
        default: return side == .buy ? ask : bid
        }
    }
    private var protectiveStop: Decimal? { bracket ? DecimalInput.positive(stopLoss) : nil }
    private var target: Decimal? { bracket ? DecimalInput.positive(takeProfit) : nil }
    private var ledger: Ledger { Ledger(context.account, hours: context.market.hours) }
    private var heldShares: Decimal { context.live?.heldShares ?? ledger.shares(context.symbol) }
    private var equity: Decimal? {
        if isLive { return context.live?.equity }
        return ledger.value { context.market.price($0) ?? ($0 == context.symbol ? reference : nil) }
    }
    private var riskBudget: Decimal? {
        guard let equity, let pct = DecimalInput.positive(riskPercent) else { return nil }
        return (equity * pct / 100).rounded(Precision.cash)
    }
    private var allowedTypes: [OrderType] {
        OrderType.allCases.filter { !context.locked.contains(.advancedOrders) || !($0 == .stopLimit || $0 == .trailingStop) }
    }

    private var shares: Decimal {
        switch sizing {
        case .shares: return DecimalInput.positive(quantity)?.rounded(Precision.shares, .down) ?? 0
        case .dollars:
            guard let dollars = DecimalInput.positive(quantity), let entry = entryPrice, entry > 0 else { return 0 }
            return (dollars / entry).rounded(isLive ? 0 : Precision.shares, .down)
        case .risk:
            guard let budget = riskBudget, let entry = entryPrice, let stop = protectiveStop else { return 0 }
            return OrderEngine.shares(risking: budget, entry: entry, stop: stop, fractional: false)
        }
    }

    private var request: OrderRequest {
        var r = OrderRequest(symbol: context.symbol, side: side, shares: shares, type: type)
        r.limit = type.usesLimit ? limitPrice : nil
        r.stop = type.usesStop ? stopPrice : nil
        if type == .trailingStop {
            let value = DecimalInput.positive(trail)
            if trailInPercent { r.trailPercent = value.map { $0 / 100 } } else { r.trailAmount = value }
        }
        r.tif = tif
        r.extendedHours = extendedHours && type == .limit
        r.takeProfit = target
        r.stopLoss = protectiveStop
        // Closing trades don't carry a bracket; a stop on an entry doubles as the planned stop for reviews.
        if closesPosition { r.takeProfit = nil; r.stopLoss = nil; r.reduceOnly = !isLive }
        r.thesis = thesis.trimmingCharacters(in: .whitespacesAndNewlines)
        r.invalidation = invalidation.trimmingCharacters(in: .whitespacesAndNewlines)
        r.horizon = horizon.trimmingCharacters(in: .whitespacesAndNewlines)
        return r
    }

    /// True when this order only reduces an existing position.
    private var closesPosition: Bool {
        (side == .sell && heldShares > 0 && shares <= heldShares) || (side == .buy && heldShares < 0 && shares <= -heldShares)
    }

    /// Practice: dry run with the same engine and rules as the real submit. Real money: Alpaca's rules.
    private var preview: Result<PracticeOrder, OrderRejection>? {
        guard !isLive else { return nil }
        var copy = context.account
        return OrderEngine.submit(request, kind: context.kind, account: &copy, quote: context.quote, context: context.market)
    }
    private var liveProblem: String? { isLive ? AlpacaTrading.validate(request) : nil }

    private var riskPerShare: Decimal? {
        guard let entry = entryPrice, let stop = protectiveStop else { return nil }
        return abs(entry - stop)
    }
    private var rewardRisk: Double? {
        guard let risk = riskPerShare, risk > 0, let entry = entryPrice, let target else { return nil }
        return (abs(target - entry) / risk).double
    }
    private var coachNotes: [CoachNote] { shares > 0 ? (context.coach?(request, entryPrice) ?? []) : [] }
    private var coolingDown: Bool { !ignoreCoolDown && (context.coolDownUntil ?? .distantPast) > Date() && !closesPosition }

    // MARK: View

    var body: some View {
        NavigationStack {
            Form {
                if isLive { liveBanner }
                if coolingDown { coolDownBanner }
                Section {
                    Picker("Side", selection: $side) {
                        ForEach(OrderSide.allCases) { s in
                            Text(s == .buy ? (heldShares < 0 ? "Buy back" : "Buy") : (heldShares > 0 ? "Sell" : context.locked.contains(.shorting) ? "Sell" : "Sell short")).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    quoteRow
                    HStack {
                        Picker("Order type", selection: $type) { ForEach(allowedTypes, id: \.self) { Text(typeName($0)).tag($0) } }
                        ExplainButton(term: typeTerm)
                    }
                    Text(typeHelp).font(theme.meta).foregroundStyle(theme.muted)
                    if type.usesStop {
                        priceField(type == .stop ? "Trigger price" : "Stop (trigger) price", text: $stop, presets: stopPresets)
                    }
                    if type.usesLimit {
                        priceField(type == .limit ? "Your price" : "Limit price", text: $limit, presets: limitPresets)
                    }
                    if type == .trailingStop {
                        HStack {
                            TextField(trailInPercent ? "Follow by %" : "Follow by $", text: $trail).appNumberKeyboard(.decimal)
                            Picker("", selection: $trailInPercent) { Text("$").tag(false); Text("%").tag(true) }.pickerStyle(.segmented).frame(width: 90)
                        }
                    }
                } footer: {
                    if context.locked.contains(.advancedOrders) { Text("More order types unlock as you finish lessons in Learn.") }
                }
                Section {
                    Picker("Size by", selection: $sizing) { ForEach(Sizing.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    switch sizing {
                    case .shares:
                        TextField("Number of shares", text: $quantity).appNumberKeyboard(.decimal)
                        quickSizes
                    case .dollars:
                        TextField("Dollar amount", text: $quantity).appNumberKeyboard(.decimal)
                        ExplainRow("Shares", value: Format.shares(shares))
                    case .risk:
                        HStack { TextField("Most I'll lose, as % of my account", text: $riskPercent).appNumberKeyboard(.decimal); Text("%").foregroundStyle(theme.muted) }
                        ExplainRow("That's at most", value: riskBudget.map(Format.money) ?? "—")
                        if protectiveStop == nil { Text("Set a stop loss below to size by risk.").font(theme.meta).foregroundStyle(theme.muted) }
                        ExplainRow("Shares", value: Format.shares(shares))
                    }
                } header: {
                    HStack(spacing: 2) { Text("How many"); ExplainButton(term: "Position sizing", size: 12) }
                }
                if !closesPosition {
                    Section {
                        Toggle("Stop loss and profit target", isOn: $bracket.animation())
                        if bracket {
                            priceField("Stop loss: exit if it falls to", text: $stopLoss, presets: stopLossPresets, label: side == .buy ? nil : "Stop loss: exit if it rises to")
                            priceField("Profit target (optional)", text: $takeProfit, presets: targetPresets)
                        }
                    } header: {
                        HStack(spacing: 2) { Text("Automatic exits"); ExplainButton(term: "Bracket order", size: 12) }
                    } footer: {
                        Text("Both wait until your order fills. When one of them happens, the other is canceled automatically.")
                    }
                }
                Section {
                    Picker("Order lasts", selection: $tif) { ForEach(TimeInForce.allCases, id: \.self) { Text($0 == .day ? "Until today's close" : "Until filled or canceled").tag($0) } }
                    if type == .limit && !context.isReplay && !context.locked.contains(.extendedHours) {
                        Toggle("Also work before/after regular hours", isOn: $extendedHours)
                    }
                } header: {
                    HStack(spacing: 2) { Text("Timing"); ExplainButton(term: "Time in force", size: 12) }
                }
                riskSection
                if !coachNotes.isEmpty { coachSection }
                Section("Your plan") {
                    Picker("Setup", selection: $strategy) { ForEach(TradeNote.strategies, id: \.self) { Text($0) } }
                    Stepper("Confidence: \(confidence) of 5", value: $confidence, in: 1...5)
                    TextField("Why are you taking this trade?", text: $thesis, axis: .vertical).lineLimit(1...3)
                    TextField("What would tell you you're wrong?", text: $invalidation, axis: .vertical).lineLimit(1...3)
                    TextField("How long do you plan to hold?", text: $horizon)
                }
            }
            .scrollContentBackground(.hidden).background(theme.paper)
            .safeAreaInset(edge: .bottom) { submitBar }
            .navigationTitle(context.isReplay ? "Replay order · \(context.symbol)" : isLive ? "Real order · \(context.symbol)" : context.symbol).appInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog(isLive ? "Send a REAL order?" : submitTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(isLive ? "Send real order: \(submitTitle)" : submitTitle) { send() }
            } message: { Text(confirmMessage) }
        }
        .explainHost(store: nil)
    }

    private var liveBanner: some View {
        Section {
            Label(context.live?.environment == .live ? "Real money. This order goes to your Alpaca account and can lose real dollars."
                  : "Alpaca paper account (fake money at a real broker).", systemImage: context.live?.environment == .live ? "exclamationmark.octagon.fill" : "testtube.2")
                .font(theme.label).foregroundStyle(context.live?.environment == .live ? theme.loss : theme.warning)
            if let bp = context.live?.buyingPower { ExplainRow("Buying power at Alpaca", value: Format.money(bp)) }
        }
    }

    private var coolDownBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: Space.s8) {
                Label("You're taking a break", systemImage: "cup.and.saucer.fill").font(theme.label)
                Text("Your break ends at \((context.coolDownUntil ?? Date()).formatted(date: .omitted, time: .shortened)). Breaks after a losing streak help you come back with a clear head.")
                    .font(theme.meta).foregroundStyle(theme.muted)
                Button("Trade anyway") { ignoreCoolDown = true }.font(theme.meta)
            }
        }
    }

    private var coachSection: some View {
        Section {
            ForEach(coachNotes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Label(note.title, systemImage: note.level == .warning ? "exclamationmark.triangle.fill" : note.level == .caution ? "exclamationmark.circle" : "lightbulb")
                        .font(theme.label).foregroundStyle(note.level == .warning ? theme.loss : note.level == .caution ? theme.warning : theme.ink)
                    Text(note.detail).font(theme.meta).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                    if let id = note.lessonID, let lesson = Curriculum.content.pathLesson(id) {
                        NavigationLink("Lesson: \(lesson.title)") { LessonPreview(lesson: lesson) }.font(theme.meta)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: { Text("Coach") } footer: { Text("Suggestions only. You can still place the order.") }
    }

    private func typeName(_ t: OrderType) -> String {
        switch t {
        case .market: return "Market (now)"
        case .limit: return "Limit (my price)"
        case .stop: return "Stop"
        case .stopLimit: return "Stop limit"
        case .trailingStop: return "Trailing stop"
        }
    }
    private var typeTerm: String {
        switch type { case .market: return "Market order"; case .limit: return "Limit order"; case .stop: return "Stop loss"; case .stopLimit: return "Stop-limit order"; case .trailingStop: return "Trailing stop" }
    }
    private var typeHelp: String {
        switch type {
        case .market: return "Fills right away at about the \(side == .buy ? "ask" : "bid") price."
        case .limit: return side == .buy ? "Only buys at your price or lower. It may never fill." : "Only sells at your price or higher. It may never fill."
        case .stop: return side == .buy ? "Buys at market once the price rises to your trigger." : "Sells at market once the price falls to your trigger."
        case .stopLimit: return "Once the trigger price trades, places a limit order at your limit price."
        case .trailingStop: return "A stop that follows the price as it moves your way, and never moves back."
        }
    }

    private var quoteRow: some View {
        HStack {
            if let quote = context.quote, let bid, let ask {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) { Text("Sell price \(Format.money(bid))").foregroundStyle(theme.stockLoss); ExplainButton(term: "Bid", size: 11) }
                    HStack(spacing: 2) { Text("Buy price \(Format.money(ask))").foregroundStyle(theme.stockGain); ExplainButton(term: "Ask", size: 11) }
                }.font(theme.label.monospacedDigit())
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last \(Format.money(quote.price))").font(theme.label.monospacedDigit())
                    Text(quote.bid == nil && !isLive && settings.fillModel == .realistic ? "Estimated spread" : quote.source.rawValue.prefix(1).uppercased() + quote.source.rawValue.dropFirst())
                        .font(theme.meta).foregroundStyle(theme.muted)
                }
            } else {
                Text("Waiting for a price").foregroundStyle(theme.muted)
            }
        }
    }

    private var quickSizes: some View {
        HStack {
            ForEach(["1", "5", "10", "25", "100"], id: \.self) { value in
                Button(value) { quantity = value }.buttonStyle(.bordered).font(theme.meta)
            }
            if side == .sell, heldShares > 0 {
                Button("All") { quantity = Format.plain(heldShares) }.buttonStyle(.bordered).font(theme.meta)
            }
            if side == .buy, heldShares < 0 {
                Button("All") { quantity = Format.plain(-heldShares) }.buttonStyle(.bordered).font(theme.meta)
            }
        }
    }

    private func priceField(_ title: String, text: Binding<String>, presets: [(String, Decimal)], label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            HStack {
                Text(label ?? title)
                Spacer()
                TextField("0.00", text: text).appNumberKeyboard(.decimal).multilineTextAlignment(.trailing).frame(maxWidth: 140)
            }
            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(presets, id: \.0) { preset in
                            Button(preset.0) { text.wrappedValue = Format.plain(preset.1.tickRounded) }.buttonStyle(.bordered).font(theme.meta)
                        }
                    }
                }
            }
        }
    }

    private var limitPresets: [(String, Decimal)] {
        guard let bid, let ask, let quote = context.quote else { return [] }
        return [("Sell price", bid), ("Middle", (bid + ask) / 2), ("Buy price", ask), ("Last", quote.price)]
    }

    private var stopPresets: [(String, Decimal)] {
        guard let last = reference else { return [] }
        let direction: Decimal = side == .buy ? 1 : -1
        return ["0.5%", "1%", "2%"].compactMap { label in
            guard let pct = Decimal(string: label.replacingOccurrences(of: "%", with: "")) else { return nil }
            return (label, last * (1 + direction * pct / 100))
        }
    }

    private var stopLossPresets: [(String, Decimal)] {
        guard let entry = entryPrice else { return [] }
        let direction: Decimal = side == .buy ? -1 : 1
        var presets: [(String, Decimal)] = []
        if let atr = context.atr, atr > 0 {
            presets.append(("1× normal move", entry + direction * Decimal.price(atr)))
            presets.append(("2× normal move", entry + direction * Decimal.price(atr * 2)))
        }
        presets.append(("1% away", entry * (1 + direction / 100)))
        presets.append(("2% away", entry * (1 + direction * 2 / 100)))
        return presets
    }

    private var targetPresets: [(String, Decimal)] {
        guard let entry = entryPrice, let risk = riskPerShare, risk > 0 else { return [] }
        let direction: Decimal = side == .buy ? 1 : -1
        return [("Same as risk (1R)", entry + direction * risk), ("2× risk (2R)", entry + direction * risk * 2), ("3× risk (3R)", entry + direction * risk * 3)]
    }

    private var riskSection: some View {
        Section {
            let shares = self.shares
            ExplainRow("Order value", value: entryPrice.map { Format.money(Decimal.notional(shares, $0)) } ?? "—")
            if let risk = riskPerShare, !closesPosition {
                let total = (risk * shares).rounded(Precision.cash)
                ExplainRow("You'd lose if the stop hits", value: Format.money(total))
                if let equity, equity > 0 {
                    ExplainRow("Share of your account", value: (total / equity).double.formatted(.percent.precision(.fractionLength(1))))
                }
            } else if !closesPosition {
                Text("No stop loss set, so there's no limit on what this trade could lose.").font(theme.meta).foregroundStyle(theme.warning)
            }
            if let rr = rewardRisk {
                HStack { Text("Reward vs risk"); ExplainButton(term: "Reward-to-risk", size: 11); Spacer(); Text(String(format: "%.1f to 1", rr)).monospacedDigit() }
            }
            if !isLive, let snapshot = Margin.snapshot(account: context.account, ledger: ledger,
                                                        price: { context.market.price($0) ?? ($0 == context.symbol ? reference : nil) }, now: context.market.now) {
                HStack { Text("Money available to trade"); ExplainButton(term: "Buying power", size: 11); Spacer(); Text(Format.money(snapshot.availableBuyingPower)).monospacedDigit().holdToExplain("Money available to trade", value: Format.money(snapshot.availableBuyingPower)) }
                if settings.accountType == .margin && snapshot.maintenanceRequirement > 0 {
                    ExplainRow("Margin you must keep", value: Format.money(snapshot.maintenanceRequirement))
                }
            }
            if !context.isReplay && !isLive && settings.fees(shares: shares) > 0 {
                ExplainRow("Commission", value: Format.money(settings.fees(shares: shares)))
            }
        } header: { Text("What's at risk") }
    }

    private var submitTitle: String {
        let price: String
        switch type {
        case .market: price = "at market"
        case .limit: price = "limit \(Format.plain(limitPrice))"
        case .stop: price = "stop \(Format.plain(stopPrice))"
        case .stopLimit: price = "stop \(Format.plain(stopPrice)) limit \(Format.plain(limitPrice))"
        case .trailingStop: price = "trailing stop"
        }
        let verb = side == .buy ? (heldShares < 0 ? "Buy back" : "Buy") : (heldShares > 0 ? "Sell" : "Sell short")
        return "\(verb) \(Format.shares(shares)) \(context.symbol) \(price)"
    }

    private var executionNote: String {
        if coolingDown { return "You're on a break. Tap \"Trade anyway\" above to place orders." }
        if isLive {
            if let problem = liveProblem { return problem }
            return context.live?.environment == .live ? "Goes to Alpaca with real money. Fills, prices and rules are the broker's." : "Goes to your Alpaca paper account."
        }
        switch preview {
        case .failure(let rejection)?: return rejection.message
        case .success(let order)?:
            switch order.status {
            case .filled: return "Fills now at about \(Format.money(order.fillPrice ?? 0))."
            case .queued: return "The market is closed. This fills at the first price after it opens, which can be different from now."
            case .open:
                if order.extendedHours { return "Works now in extended hours, and in the regular session." }
                return type.isStopFamily ? "Waits until the price reaches your trigger." : "Waits for your price. It may never fill."
            default: return ""
            }
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        var text = executionNote
        if let top = coachNotes.first(where: { $0.level == .warning }) { text += "\n\nCoach: \(top.title)." }
        return text
    }

    private var submitBar: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(executionNote).font(theme.meta).foregroundStyle(isValid ? theme.muted : theme.loss).lineLimit(3)
            Button {
                if settings.confirmOrders || isLive { confirming = true } else { send() }
            } label: {
                Text(submitTitle).font(theme.label).frame(maxWidth: .infinity).frame(minHeight: 50)
                    .foregroundStyle(.white)
                    .background(isValid ? (side == .buy ? theme.stockGain : theme.stockLoss) : theme.line, in: RoundedRectangle(cornerRadius: Space.smallRadius))
            }
            .buttonStyle(.plain)
            .disabled(!isValid)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, Space.s24).padding(.vertical, Space.s12)
        .background(theme.paper).overlay(alignment: .top) { Rule() }
    }

    private var isValid: Bool {
        guard shares > 0, !coolingDown else { return false }
        if isLive { return liveProblem == nil && (context.quote != nil || type != .market) }
        if case .success? = preview { return true }
        return false
    }

    private func send() {
        if submit(request, TradeNote(strategy: strategy, confidence: confidence)) { dismiss() }
    }
}

/// Read-only lesson preview opened from the coach inside the ticket.
struct LessonPreview: View {
    @Environment(\.theme) private var theme
    let lesson: PathLesson
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text(lesson.title).font(theme.page)
                if let graphic = lesson.graphic { ConceptGraphic(kind: graphic).frame(height: 150) }
                ForEach(lesson.pages, id: \.self) { Text($0).font(theme.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
                Text("Take the quiz for this lesson in Learn.").font(theme.meta).foregroundStyle(theme.muted)
            }
            .padding(Space.s24)
        }
        .background(theme.paper)
        .navigationTitle("Lesson").appInlineTitle()
    }
}
