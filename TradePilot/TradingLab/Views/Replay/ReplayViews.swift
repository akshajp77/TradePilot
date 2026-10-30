import SwiftUI

/// Bar replay: trade a past session bar by bar with the same order engine, in a $25k sandbox.
struct ReplayHomeView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore

    var body: some View {
        Group {
            if store.replay != nil {
                ReplaySessionView(store: store)
            } else {
                ReplaySetupView(store: store)
            }
        }
        .navigationTitle("Bar replay").appInlineTitle()
    }
}

private struct ReplaySetupView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var symbol = ""
    @State private var timeframe: Timeframe = .m1
    @State private var days: [Date] = []
    @State private var day: Date?
    @State private var loadingDays = false

    var body: some View {
        Form {
            Section {
                Text("Pick a recent session. The chart stops at the open; reveal one bar at a time and trade as if it were live. Fills follow each bar's open → low → high → close (or high first on down bars).")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
            Section("Session") {
                TextField("Symbol, e.g. SPY", text: $symbol).appCapitalization(.characters)
                    .onSubmit { Task { await loadDays() } }
                Picker("Bars", selection: $timeframe) {
                    Text("1 minute (last ~5 sessions)").tag(Timeframe.m1)
                    Text("5 minutes (last ~month)").tag(Timeframe.m5)
                    Text("15 minutes (last ~month)").tag(Timeframe.m15)
                }
                Button { Task { await loadDays() } } label: {
                    HStack { Text("Find sessions"); if loadingDays { Spacer(); ProgressView() } }
                }.disabled(cleanSymbol.isEmpty || loadingDays)
                if !days.isEmpty {
                    Picker("Day", selection: $day) {
                        ForEach(days, id: \.self) { Text($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).tag(Optional($0)) }
                    }
                }
            }
            Section {
                Button {
                    guard let day else { return }
                    Task { await store.startReplay(symbol: cleanSymbol, day: day, timeframe: timeframe) }
                } label: {
                    HStack { Text("Start replay").font(theme.label); if store.replayLoading { Spacer(); ProgressView() } }
                }
                .disabled(day == nil || store.replayLoading)
            }
            if !store.features.barReplays.isEmpty {
                Section("Past replays") {
                    ForEach(store.features.barReplays) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(record.symbol) · \(record.timeframe.rawValue)").font(theme.label)
                                Text(record.day.formatted(date: .abbreviated, time: .omitted)).font(theme.meta).foregroundStyle(theme.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Format.signedMoney(record.netPnL)).font(theme.label.monospacedDigit()).foregroundStyle(theme.gain(record.netPnL >= 0))
                                    .holdToExplain("Net P&L", value: Format.signedMoney(record.netPnL), context: ["From a past replay session."], tone: theme.gain(record.netPnL >= 0), practice: false)
                                Text("\(record.trades) trades · \(record.winRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—") win")
                                    .font(theme.meta).foregroundStyle(theme.muted)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .onAppear { if symbol.isEmpty { symbol = store.chartSymbol } }
        .onChange(of: timeframe) { _, _ in days = []; day = nil }
        .onChange(of: symbol) { _, _ in days = []; day = nil }
    }

    private var cleanSymbol: String { symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    private func loadDays() async {
        guard !cleanSymbol.isEmpty else { return }
        loadingDays = true
        defer { loadingDays = false }
        guard await store.ensureSecurity(cleanSymbol) != nil else { return }
        await store.market.loadBars(cleanSymbol, timeframe: timeframe, force: true)
        days = store.replayDays(symbol: cleanSymbol, timeframe: timeframe)
        day = days.first
        if days.isEmpty { store.notice = "No \(timeframe.rawValue) sessions found for \(cleanSymbol)." }
    }
}

private struct ReplaySessionView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var tool: DrawingTool?
    @State private var playing = false
    @State private var speed = 1.0
    @State private var quantity = 100.0
    @State private var ticket: TicketDraft?
    @State private var confirmFinish = false

    var body: some View {
        if let session = store.replay {
            VStack(spacing: 0) {
                header(session)
                Rule()
                ProChartView(
                    data: .build(bars: session.visibleBars, timeframe: session.timeframe, preferences: store.chartPreferences, previousClose: nil, hours: session.hours),
                    style: store.chartPreferences.style, showVolume: store.chartPreferences.showVolume,
                    resetKey: "replay-\(session.symbol)-\(session.day.timeIntervalSince1970)",
                    orderLines: lines(session), position: positionLine(session), executions: executions(session),
                    lastPrice: session.currentBar?.close, tool: $tool, magnet: store.chartPreferences.magnet,
                    onPriceAction: { price in
                        let last = session.currentBar?.close ?? price
                        ticket = TicketDraft(side: price < last ? .buy : .sell, type: .limit, price: Decimal.price(price).tickRounded)
                    }
                )
                Rule()
                controls(session)
            }
            .background(theme.paper.ignoresSafeArea())
            .task(id: playing) {
                guard playing else { return }
                while playing && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(Int(1000 / speed)))
                    guard playing, let current = store.replay, !current.isFinished else { playing = false; return }
                    store.replayStep()
                }
            }
            .sheet(item: $ticket) { draft in
                OrderTicketView(context: TicketContext(symbol: session.symbol, kind: .stock, quote: session.quote, account: session.account,
                                                       market: session.context, atr: Indicators.atr(session.visibleBars).last ?? nil, isReplay: true),
                                side: draft.side, type: draft.type, price: draft.price) { request, _ in store.replaySubmit(request) }
                    .environment(\.theme, theme)
            }
            .confirmationDialog("Finish this replay?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish and save result") { playing = false; store.finishReplay() }
                Button("Discard", role: .destructive) { playing = false; store.replay = nil }
            } message: { Text("Remaining bars play out against your working orders, then any open position closes at the last price.") }
        }
    }

    private func header(_ session: ReplaySession) -> some View {
        let ledger = Ledger(session.account, hours: session.hours)
        let price = session.quote?.price
        let equity = ledger.value { $0 == session.symbol ? price : nil } ?? session.account.initialBalance
        let pnl = equity - session.account.initialBalance
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.symbol) · \(session.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))").font(theme.label)
                    Text(session.currentBar.map { $0.time.formatted(Date.FormatStyle(timeZone: session.hours.timeZone).hour().minute()) + " ET" } ?? "")
                        .font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.signedMoney(pnl)).font(theme.label.monospacedDigit()).foregroundStyle(theme.gain(pnl >= 0))
                        .holdToExplain("Net P&L", value: Format.signedMoney(pnl), context: ["In this replay session."], tone: theme.gain(pnl >= 0), practice: false)
                    if let position = ledger.position(session.symbol) {
                        Text("\(position.isLong ? "Long" : "Short") \(Format.shares(position.size)) @ \(Format.money(position.averagePrice ?? 0))")
                            .font(theme.meta).foregroundStyle(theme.muted)
                    } else {
                        Text("Flat").font(theme.meta).foregroundStyle(theme.muted)
                    }
                }
            }
            ProgressView(value: session.progress).tint(theme.accent)
        }
        .padding(.horizontal, Space.s12).padding(.vertical, Space.s8)
    }

    private func controls(_ session: ReplaySession) -> some View {
        let ledger = Ledger(session.account, hours: session.hours)
        let working = session.account.orders.filter { $0.status.isPending }
        return VStack(spacing: Space.s8) {
            HStack(spacing: Space.s12) {
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 36, height: 36) }
                    .accessibilityLabel(playing ? "Pause" : "Play").keyboardShortcut(.space, modifiers: [])
                Button { store.replayStep() } label: { Image(systemName: "forward.frame.fill").frame(width: 36, height: 36) }
                    .accessibilityLabel("Next bar").keyboardShortcut(.rightArrow, modifiers: [])
                Button { store.replayStep(5) } label: { Text("+5").font(theme.label).frame(width: 36, height: 36) }
                    .accessibilityLabel("Skip 5 bars")
                Menu {
                    Picker("Speed", selection: $speed) { ForEach([0.5, 1, 2, 5, 10], id: \.self) { Text("\($0.formatted())× bars/sec").tag($0) } }
                } label: { Text("\(speed.formatted())×").font(theme.meta).frame(width: 40, height: 36) }
                Spacer()
                Button("Finish") { confirmFinish = true }.font(theme.label)
            }
            .buttonStyle(.plain)
            HStack(spacing: Space.s8) {
                HStack(spacing: 0) {
                    Button { quantity = max(1, quantity - (quantity > 100 ? 50 : 10)) } label: { Image(systemName: "minus").frame(width: 28, height: 40) }
                    Text(Format.shares(Decimal(quantity))).font(theme.label.monospacedDigit()).frame(minWidth: 44)
                    Button { quantity += quantity >= 100 ? 50 : 10 } label: { Image(systemName: "plus").frame(width: 28, height: 40) }
                }
                .buttonStyle(.plain).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                replayButton(.sell, session)
                replayButton(.buy, session)
            }
            HStack {
                if let position = ledger.position(session.symbol) {
                    Button("Flatten") {
                        var request = OrderRequest(symbol: session.symbol, side: position.isLong ? .sell : .buy, shares: position.size, type: .market)
                        request.reduceOnly = true
                        request.role = .exit
                        store.replaySubmit(request)
                        for order in working where order.reduceOnly || order.role != .entry { store.replayCancel(order.id) }
                    }.font(theme.meta.weight(.semibold)).foregroundStyle(theme.loss)
                }
                if !working.isEmpty {
                    Menu("\(working.count) working") {
                        ForEach(working) { order in Button("Cancel \(order.summary)") { store.replayCancel(order.id) } }
                    }.font(theme.meta)
                }
                Spacer()
                Button { ticket = TicketDraft(side: .buy) } label: { Label("Ticket", systemImage: "list.bullet.rectangle") }.font(theme.meta)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, Space.s12).padding(.vertical, Space.s8)
    }

    private func replayButton(_ side: OrderSide, _ session: ReplaySession) -> some View {
        Button {
            store.replaySubmit(OrderRequest(symbol: session.symbol, side: side, shares: Decimal(quantity), type: .market))
        } label: {
            VStack(spacing: 1) {
                Text(side == .buy ? "BUY" : "SELL").font(.system(size: 13, weight: .bold))
                Text(session.quote.map { Format.money(side == .buy ? OrderEngine.ask($0, session.account.settings) : OrderEngine.bid($0, session.account.settings)) } ?? "—")
                    .font(.system(size: 11).monospacedDigit()).opacity(0.9)
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 40)
            .background(side == .buy ? theme.stockGain : theme.stockLoss, in: RoundedRectangle(cornerRadius: Space.smallRadius))
        }
        .buttonStyle(.plain)
        .disabled(session.isFinished)
    }

    private func lines(_ session: ReplaySession) -> [ChartOrderLine] {
        session.account.orders.filter { $0.status.isPending }.compactMap { order in
            guard let price = order.type == .limit ? order.limit : (order.effectiveStop ?? order.limit) else { return nil }
            let kind: ChartOrderLine.Kind = order.role == .stopLoss ? .stop : order.role == .takeProfit ? .target : .entry
            return ChartOrderLine(id: order.id, price: price.double, label: "\(order.side == .buy ? "BUY" : "SELL") \(Format.shares(order.shares))",
                                  kind: kind, side: order.side, draggable: false)
        }
    }

    private func positionLine(_ session: ReplaySession) -> ChartPositionLine? {
        let ledger = Ledger(session.account, hours: session.hours)
        guard let position = ledger.position(session.symbol), let average = position.averagePrice, let price = session.quote?.price else { return nil }
        let pnl = position.unrealized(price)
        return ChartPositionLine(price: average.double, label: "\(position.isLong ? "LONG" : "SHORT") \(Format.shares(position.size)) \(Format.signedMoney(pnl))", isProfit: pnl >= 0)
    }

    private func executions(_ session: ReplaySession) -> [ChartExecution] {
        session.account.orders.compactMap { o in
            guard o.status == .filled, let t = o.filledAt, let p = o.fillPrice else { return nil }
            return ChartExecution(time: t, price: p.double, side: o.side)
        }
    }

}
