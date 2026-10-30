import SwiftUI

/// A ticket the chart wants to open: side, type and an optional price from the crosshair.
struct TicketDraft: Identifiable {
    let id = UUID()
    var side: OrderSide
    var type: OrderType = .market
    var price: Decimal? = nil
}

/// The Chart tab: a TradingView-style chart with one-tap trading, order lines you can drag,
/// Level 1, time & sales and the blotter. Wide layouts get a trading sidebar.
struct ChartScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @ObservedObject var broker: BrokerService

    @State private var tool: DrawingTool?
    @State private var ticket: TicketDraft?
    @State private var pickingSymbol = false
    @State private var editingIndicators = false
    @State private var priceAction: Double?
    @State private var panel: Panel = .positions
    @State private var showPanel = true
    @AppStorage("chart-quick-quantity") private var quickQuantity = 10.0
    @AppStorage("chart-live-mode") private var liveMode = false

    enum Panel: String, CaseIterable { case positions = "Positions", orders = "Orders", fills = "Fills", tape = "Tape" }

    private var symbol: String { store.chartSymbol }
    /// Orders go to the connected Alpaca account instead of the practice simulator.
    private var live: Bool { liveMode && broker.isConnected }
    private var prefs: ChartPreferences { store.chartPreferences }
    private var isWide: Bool {
        #if os(macOS)
        return true
        #else
        return sizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    chartColumn
                    Rectangle().fill(theme.line).frame(width: 1)
                    sidebar.frame(width: 330)
                }
            } else {
                VStack(spacing: 0) {
                    chartColumn
                    if showPanel { compactPanel.frame(height: 210) }
                }
            }
        }
        .background(theme.paper.ignoresSafeArea())
        .navigationTitle("Chart").appInlineTitle()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: "\(symbol)|\(prefs.timeframe.rawValue)") {
            market.focus(symbol, timeframe: prefs.timeframe)
            await market.loadBars(symbol, timeframe: prefs.timeframe)
            if market.price(symbol) == nil { await market.loadDelayed([symbol]) }
        }
        .onDisappear { market.focus(nil, timeframe: prefs.timeframe) }
        .onAppear { if live { broker.startPolling() } }
        .onDisappear { if live { broker.stopPolling() } }
        .onChange(of: live) { _, isLive in if isLive { broker.startPolling() } else { broker.stopPolling() } }
        .sheet(item: $ticket) { draft in
            if live, let liveContext = store.liveTicketContext(symbol) {
                OrderTicketView(context: liveContext, side: draft.side, type: draft.type, price: draft.price) { request, _ in
                    store.placeLive(request)
                }
                .environment(\.theme, theme)
            } else {
                OrderTicketView(context: ticketContext, side: draft.side, type: draft.type, price: draft.price) { request, note in
                    store.place(request, note: note) != nil
                }
                .environment(\.theme, theme)
            }
        }
        .sheet(isPresented: $pickingSymbol) {
            SymbolPicker(store: store, market: market) { store.chartSymbol = $0 }.explainHost(store: store).environment(\.theme, theme)
        }
        .sheet(isPresented: $editingIndicators) {
            IndicatorEditor(preferences: Binding(get: { store.chartPreferences }, set: { store.chartPreferences = $0 }))
                .environment(\.theme, theme)
        }
        .confirmationDialog(priceAction.map { "At \(Format.price($0))" } ?? "", isPresented: Binding(get: { priceAction != nil }, set: { if !$0 { priceAction = nil } }), titleVisibility: .visible) {
            priceActionButtons
        }
        .background { shortcuts }
    }

    // MARK: Chart column

    private var chartColumn: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Rule()
            chart
            if !isWide { Rule(); tradeBar.padding(.horizontal, Space.s12).padding(.vertical, Space.s8) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s12) {
            Button { pickingSymbol = true } label: {
                HStack(spacing: 4) {
                    Text(symbol).font(theme.section).holdToExplainSymbol(symbol)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.muted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Symbol \(symbol). Change symbol")
            VStack(alignment: .leading, spacing: 1) {
                if let price = market.price(symbol) {
                    HStack(spacing: 6) {
                        Text(Format.price(price)).font(theme.label.monospacedDigit())
                            .holdToExplain("Last price", value: Format.price(price), symbol: symbol)
                        if let change = market.change(symbol) {
                            Text(Format.percent(change / 100)).font(theme.meta.monospacedDigit()).foregroundStyle(theme.movement(change >= 0))
                                .holdToExplain("Change today", value: Format.percent(change / 100), symbol: symbol, tone: theme.movement(change >= 0))
                        }
                    }
                } else {
                    Text("—").font(theme.label)
                }
                Text(market.quoteLabel(symbol)).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if broker.isConnected { venueToggle }
            if let l1 = market.level1[symbol] {
                HStack(spacing: 4) {
                    Text(Format.price(l1.bid)).foregroundStyle(theme.stockLoss)
                    Text("/").foregroundStyle(theme.muted)
                    Text(Format.price(l1.ask)).foregroundStyle(theme.stockGain)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Bid \(Format.price(l1.bid)), ask \(Format.price(l1.ask))")
                .holdToExplain("Bid / ask", value: "\(Format.price(l1.bid)) / \(Format.price(l1.ask))", term: "Spread", symbol: symbol, context: ["Bid \(Format.price(l1.bid)): the most a buyer will pay right now.", "Ask \(Format.price(l1.ask)): the least a seller will accept right now.", "The gap between them, \(Format.price(l1.ask - l1.bid)), is the spread."])
            }
            if let earnings = market.nextEarnings(symbol), earnings.date.timeIntervalSinceNow < 14 * 86_400 {
                Text("E \(earnings.date.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(theme.orange)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.orange, lineWidth: 1))
                    .accessibilityLabel("Earnings \(earnings.date.formatted(date: .abbreviated, time: .omitted)) \(earnings.timing)")
            }
        }
        .padding(.horizontal, Space.s12).padding(.top, Space.s8).padding(.bottom, 6)
    }

    private var venueToggle: some View {
        Button {
            if live { liveMode = false; return }
            if let env = broker.environment, !store.liveTradingAllowed(env) {
                store.notice = "Real-money trading unlocks after the practice checklist in Settings → Real-money trading."
                return
            }
            liveMode = true
        } label: {
            Text(live ? (broker.isLive ? "REAL $" : "ALPACA PAPER") : "PRACTICE")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .foregroundStyle(live ? .white : theme.ink)
                .background(live ? (broker.isLive ? theme.loss : theme.warning) : theme.surface, in: Capsule())
                .overlay(Capsule().stroke(theme.line, lineWidth: live ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(live ? "Trading with Alpaca. Switch to practice" : "Practice mode. Switch to Alpaca")
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Timeframe.allCases) { tf in
                        Button(tf.rawValue) { update { $0.timeframe = tf } }
                            .font(.system(size: 12, weight: prefs.timeframe == tf ? .bold : .regular))
                            .foregroundStyle(prefs.timeframe == tf ? theme.accent : theme.muted)
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(prefs.timeframe == tf ? theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(prefs.timeframe == tf ? .isSelected : [])
                    }
                }
            }
            Menu {
                Picker("Style", selection: Binding(get: { prefs.style }, set: { s in update { $0.style = s } })) {
                    ForEach(ChartStyle.allCases) { Label($0.rawValue, systemImage: $0.symbolName).tag($0) }
                }
            } label: { toolIcon(prefs.style.symbolName) }
            .accessibilityLabel("Chart style")
            Button { editingIndicators = true } label: { toolIcon("function") }
                .buttonStyle(.plain).accessibilityLabel("Indicators")
            Menu {
                ForEach(DrawingTool.allCases) { t in
                    Button { tool = (tool == t ? nil : t) } label: { Label(t.rawValue, systemImage: t.symbolName) }
                }
                if tool != nil { Button("Stop drawing") { tool = nil } }
                if !store.drawings(symbol).isEmpty {
                    Divider()
                    Button("Remove all drawings on \(symbol)", role: .destructive) { store.clearDrawings(symbol) }
                }
            } label: { toolIcon(tool?.symbolName ?? "pencil.tip", active: tool != nil) }
            .accessibilityLabel("Drawing tools")
            Menu {
                Toggle("Volume", isOn: toggle(\.showVolume))
                Toggle("Extended hours", isOn: toggle(\.showExtendedHours))
                Toggle("Orders and position", isOn: toggle(\.showOrders))
                Toggle("Executions", isOn: toggle(\.showExecutions))
                Toggle("Magnet (snap to OHLC)", isOn: toggle(\.magnet))
                if !isWide { Divider(); Toggle("Trading panel", isOn: $showPanel) }
            } label: { toolIcon("slider.horizontal.3") }
            .accessibilityLabel("Chart settings")
        }
        .menuStyle(.button).buttonStyle(.plain)
        .padding(.horizontal, Space.s8).padding(.bottom, 6)
    }

    private func toolIcon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? theme.accent : theme.ink)
            .frame(width: 32, height: 28)
            .background(active ? theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private var chart: some View {
        let bars = market.candles(symbol, prefs.timeframe)
        let data = ChartData.build(bars: bars, timeframe: prefs.timeframe, preferences: prefs,
                                   previousClose: prefs.timeframe.isIntraday ? market.previousClose(symbol) : nil, hours: market.hours)
        return ZStack {
            if bars.isEmpty {
                VStack(spacing: Space.s8) {
                    if market.hasError(symbol, timeframe: prefs.timeframe) {
                        Text("Couldn't load \(prefs.timeframe.label) bars for \(symbol).").font(theme.label)
                        Button("Try again") { Task { await market.loadBars(symbol, timeframe: prefs.timeframe, force: true) } }
                    } else {
                        ProgressView()
                        Text("Loading \(symbol)…").font(theme.meta).foregroundStyle(theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProChartView(
                    data: data, style: prefs.style, showVolume: prefs.showVolume,
                    resetKey: "\(symbol)|\(prefs.timeframe.rawValue)",
                    orderLines: prefs.showOrders ? orderLines : [],
                    position: prefs.showOrders ? positionLine : nil,
                    executions: prefs.showExecutions ? executions : [],
                    drawings: store.drawings(symbol),
                    earnings: (market.earnings[symbol] ?? []).map(\.date),
                    lastPrice: market.price(symbol),
                    tool: $tool, magnet: prefs.magnet,
                    onAddDrawing: { kind in store.addDrawing(ChartDrawing(symbol: symbol, kind: kind, colorIndex: store.drawings(symbol).count)) },
                    onDeleteDrawing: { store.removeDrawing($0) },
                    onMoveOrder: { id, price in
                        if live {
                            if let order = broker.openOrders.flatMap({ [$0] + $0.legs }).first(where: { $0.id.lowercased() == id.uuidString.lowercased() }) {
                                Task { if let error = await broker.replace(order, price: Decimal.price(price)) { store.notice = error } }
                            }
                        } else {
                            store.modify(id, price: Decimal.price(price).tickRounded)
                        }
                    },
                    onPriceAction: { priceAction = $0 }
                )
            }
            if let tool {
                VStack {
                    HStack {
                        Label(tool.needsTwoPoints ? "\(tool.rawValue): drag on the chart" : "\(tool.rawValue): tap a price", systemImage: tool.symbolName)
                            .font(theme.meta).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(theme.surface, in: Capsule())
                        Button("Done") { self.tool = nil }.font(theme.meta)
                    }
                    Spacer()
                }.padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chart overlays from the account

    private var orderLines: [ChartOrderLine] {
        if live {
            return broker.orders(symbol).compactMap { order in
                guard let id = UUID(uuidString: order.id), let price = order.type == "limit" ? order.limit : (order.stop ?? order.limit) else { return nil }
                let kind: ChartOrderLine.Kind = order.type == "stop" || order.type == "stop_limit" ? .stop : .entry
                return ChartOrderLine(id: id, price: price.double, label: "\(order.side == .buy ? "BUY" : "SELL") \(order.quantity.map(Format.shares) ?? "") · REAL",
                                      kind: kind, side: order.side, draggable: order.type == "limit" || order.type == "stop")
            }
        }
        return store.workingOrders(symbol).compactMap { order in
            let price: Decimal?
            switch order.type {
            case .limit: price = order.limit
            case .stopLimit: price = order.triggeredAt == nil ? order.stop : order.limit
            default: price = order.effectiveStop
            }
            guard let price else { return nil }
            let kind: ChartOrderLine.Kind = order.role == .stopLoss ? .stop : order.role == .takeProfit ? .target : (order.type.isStopFamily && order.reduceOnly ? .stop : .entry)
            let tag: String
            switch order.type {
            case .limit: tag = "LMT"
            case .stop: tag = "STP"
            case .stopLimit: tag = "STP LMT"
            case .trailingStop: tag = "TRAIL"
            case .market: tag = "MKT"
            }
            let label = "\(order.side == .buy ? "BUY" : "SELL") \(tag) \(Format.shares(order.shares))" + (order.status == .held ? " · after fill" : "")
            let draggable = order.type != .trailingStop && order.type != .market
            return ChartOrderLine(id: order.id, price: price.double, label: label, kind: kind, side: order.side, draggable: draggable)
        }
    }

    private var positionLine: ChartPositionLine? {
        if live {
            guard let p = broker.position(symbol), p.quantity != 0 else { return nil }
            return ChartPositionLine(price: p.averageEntry.double, label: "\(p.quantity > 0 ? "LONG" : "SHORT") \(Format.shares(abs(p.quantity))) \(Format.signedMoney(p.unrealized)) · REAL", isProfit: p.unrealized >= 0)
        }
        guard let position = store.position(symbol), let average = position.averagePrice else { return nil }
        let pnl = store.unrealized(symbol) ?? 0
        return ChartPositionLine(price: average.double,
                                 label: "\(position.isLong ? "LONG" : "SHORT") \(Format.shares(position.size)) \(Format.signedMoney(pnl))",
                                 isProfit: pnl >= 0)
    }

    private var executions: [ChartExecution] {
        if live {
            return broker.recentOrders.compactMap { o in
                guard o.symbol == symbol, let t = o.filledAt, let p = o.filledAverage else { return nil }
                return ChartExecution(time: t, price: p.double, side: o.side)
            }
        }
        return store.data.orders.compactMap { order in
            guard order.symbol == symbol, order.status == .filled, let time = order.filledAt, let price = order.fillPrice else { return nil }
            return ChartExecution(time: time, price: price.double, side: order.side)
        }
    }

    // MARK: Trading

    private var ticketContext: TicketContext { store.ticketContext(symbol) }

    @ViewBuilder private var priceActionButtons: some View {
        if let p = priceAction {
            let price = Decimal.price(p).tickRounded
            let last = market.price(symbol) ?? p
            if p < last {
                Button("Buy limit at \(Format.money(price))") { ticket = TicketDraft(side: .buy, type: .limit, price: price) }
                Button("Sell stop at \(Format.money(price))") { ticket = TicketDraft(side: .sell, type: .stop, price: price) }
                Button("Alert if it falls to \(Format.money(price))") { store.addAlert(symbol: symbol, condition: .priceBelow(price)); store.showToast("Alert set: \(symbol) below \(Format.money(price))") }
            } else {
                Button("Sell limit at \(Format.money(price))") { ticket = TicketDraft(side: .sell, type: .limit, price: price) }
                Button("Buy stop at \(Format.money(price))") { ticket = TicketDraft(side: .buy, type: .stop, price: price) }
                Button("Alert if it rises to \(Format.money(price))") { store.addAlert(symbol: symbol, condition: .priceAbove(price)); store.showToast("Alert set: \(symbol) above \(Format.money(price))") }
            }
            Button("Horizontal line") { store.addDrawing(ChartDrawing(symbol: symbol, kind: .horizontal(price: p), colorIndex: store.drawings(symbol).count)) }
        }
    }

    /// Quantity, one-tap buy/sell at market, the position and flatten.
    private var tradeBar: some View {
        VStack(spacing: Space.s8) {
            if store.isLockedOut {
                Label("Daily loss limit reached. New positions are locked until tomorrow.", systemImage: "lock.fill")
                    .font(theme.meta).foregroundStyle(theme.loss).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Space.s8) {
                quantityStepper
                tradeButton(.sell)
                tradeButton(.buy)
            }
            .confirmationDialog(quickConfirm.map { "\($0.rawValue) \(Format.shares(Decimal(quickQuantity))) \(symbol) at market?" } ?? "",
                                isPresented: Binding(get: { quickConfirm != nil }, set: { if !$0 { quickConfirm = nil } }), titleVisibility: .visible) {
                if let side = quickConfirm {
                    Button(live ? "\(side.rawValue) with real money" : "\(side.rawValue) at market") { sendQuick(side); quickConfirm = nil }
                    Button("Open full ticket") { ticket = TicketDraft(side: side); quickConfirm = nil }
                }
            } message: {
                Text((store.isCoolingDown ? "You're on a break after a losing streak. " : "") +
                     (live ? "This sends a market order to your Alpaca account\(broker.isLive ? " with real money" : "")." : "Turn off confirmations in Settings → Trading for true one-tap orders."))
            }
            HStack(spacing: Space.s8) {
                if live {
                    if let p = broker.position(symbol), p.quantity != 0 {
                        Text("\(p.quantity > 0 ? "Long" : "Short") \(Format.shares(abs(p.quantity))) · \(Format.signedMoney(p.unrealized))")
                            .font(theme.meta.monospacedDigit()).foregroundStyle(theme.gain(p.unrealized >= 0))
                        Button("Close") { Task { if let error = await broker.close(symbol) { store.notice = error } } }
                            .font(theme.meta.weight(.semibold)).foregroundStyle(theme.loss).buttonStyle(.borderless)
                    } else {
                        Text("Buying power \(broker.account.map { Format.money($0.buyingPower) } ?? "—")").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
                    }
                } else if let position = store.position(symbol) {
                    let pnl = store.unrealized(symbol) ?? 0
                    Text("\(position.isLong ? "Long" : "Short") \(Format.shares(position.size)) · \(Format.signedMoney(pnl))")
                        .font(theme.meta.monospacedDigit()).foregroundStyle(theme.gain(pnl >= 0))
                    Button("Close position") { store.flatten(symbol) }.font(theme.meta.weight(.semibold)).foregroundStyle(theme.loss)
                        .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 2) {
                        Text("Can spend \(Format.money(store.availableBuyingPower))").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
                        ExplainButton(term: "Buying power", size: 11)
                    }
                }
                Spacer()
                Button { ticket = TicketDraft(side: .buy) } label: { Label("Order ticket", systemImage: "list.bullet.rectangle") }
                    .font(theme.meta).buttonStyle(.borderless)
            }
        }
    }

    private var quantityStepper: some View {
        HStack(spacing: 0) {
            Button { quickQuantity = max(1, quickQuantity - step) } label: { Image(systemName: "minus").frame(width: 28, height: 40) }
                .accessibilityLabel("Fewer shares")
            Text(Format.shares(Decimal(quickQuantity))).font(theme.label.monospacedDigit()).frame(minWidth: 44)
                .accessibilityLabel("\(Int(quickQuantity)) shares")
            Button { quickQuantity += step } label: { Image(systemName: "plus").frame(width: 28, height: 40) }
                .accessibilityLabel("More shares")
        }
        .buttonStyle(.plain)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
    }

    private var step: Double { quickQuantity >= 1_000 ? 100 : quickQuantity >= 100 ? 50 : quickQuantity >= 20 ? 10 : 1 }

    private func tradeButton(_ side: OrderSide) -> some View {
        let quote = market.quote(symbol)
        let price = quote.map { q in live ? (side == .buy ? (q.ask ?? q.price) : (q.bid ?? q.price)) : (side == .buy ? OrderEngine.ask(q, store.settings) : OrderEngine.bid(q, store.settings)) }
        return Button { quick(side) } label: {
            VStack(spacing: 1) {
                Text(side == .buy ? "BUY" : "SELL").font(.system(size: 13, weight: .bold))
                Text(price.map(Format.money) ?? "—").font(.system(size: 11).monospacedDigit()).opacity(0.9)
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 40)
            .background(side == .buy ? theme.stockGain : theme.stockLoss, in: RoundedRectangle(cornerRadius: Space.smallRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(side == .buy ? "Buy" : "Sell") \(Int(quickQuantity)) shares at market")
    }

    /// Quick orders still get a one-tap confirmation when "Confirm orders" is on, and always for real money.
    @State private var quickConfirm: OrderSide?

    private func quick(_ side: OrderSide) {
        if live || store.settings.confirmOrders || store.isCoolingDown { quickConfirm = side } else { sendQuick(side) }
    }

    private func sendQuick(_ side: OrderSide) {
        let request = OrderRequest(symbol: symbol, side: side, shares: Decimal(quickQuantity), type: .market)
        if live { store.placeLive(request) } else { store.quickOrder(symbol, side: side, shares: request.shares) }
    }

    // MARK: Panels

    private var compactPanel: some View {
        VStack(spacing: 0) {
            Rule()
            Picker("Panel", selection: $panel) { ForEach(Panel.allCases, id: \.self) { Text(title($0)).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, Space.s12).padding(.vertical, 6)
            ScrollView { panelContent(panel).padding(.horizontal, Space.s12) }
        }
        .background(theme.paper)
    }

    private func title(_ panel: Panel) -> String {
        switch panel {
        case .positions: return "Positions \(live ? broker.positions.count : store.heldSymbols.count)"
        case .orders: return "Orders \(live ? broker.openOrders.count : store.workingOrders.count)"
        default: return panel.rawValue
        }
    }

    @ViewBuilder private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .positions:
            if live { LivePositionsList(store: store, broker: broker) { store.chartSymbol = $0 } }
            else { PositionsBlotter(store: store, market: market) { store.chartSymbol = $0 } }
        case .orders:
            if live { LiveOrdersList(store: store, broker: broker) } else { OrdersBlotter(store: store) }
        case .fills:
            if live { LiveFillsList(broker: broker) } else { FillsBlotter(store: store) }
        case .tape: TapeView(market: market)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Eyebrow(text: "Trade \(symbol)")
                tradeBar
                Level1View(market: market, symbol: symbol)
                Rule()
                Picker("Panel", selection: $panel) { ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                panelContent(panel)
                if panel != .tape {
                    Eyebrow(text: "Time & sales")
                    TapeView(market: market, limit: 30)
                }
            }
            .padding(Space.s16)
        }
        .background(theme.paper)
    }

    // MARK: Keyboard

    private var shortcuts: some View {
        Group {
            Button("") { quick(.buy) }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("") { quick(.sell) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { if live { Task { _ = await broker.close(symbol) } } else { store.flatten(symbol) } }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { ticket = TicketDraft(side: .buy) }.keyboardShortcut("t", modifiers: .command)
            Button("") { pickingSymbol = true }.keyboardShortcut("k", modifiers: .command)
            Button("") { tool = nil }.keyboardShortcut(.escape, modifiers: [])
            ForEach(Array(Timeframe.allCases.enumerated()), id: \.offset) { index, tf in
                Button("") { update { $0.timeframe = tf } }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: Preferences

    private func update(_ change: (inout ChartPreferences) -> Void) {
        var copy = store.chartPreferences
        change(&copy)
        store.chartPreferences = copy
    }

    private func toggle(_ key: WritableKeyPath<ChartPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { store.chartPreferences[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
}
