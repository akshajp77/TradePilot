import SwiftUI

/// Open positions with live P&L and one-tap actions.
struct PositionsBlotter: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    var onSelect: (String) -> Void = { _ in }
    @State private var protecting: String?
    @State private var confirmFlatten: String?

    var body: some View {
        let symbols = store.heldSymbols
        VStack(alignment: .leading, spacing: 0) {
            if symbols.isEmpty {
                Text("No open positions.").font(theme.label).foregroundStyle(theme.muted).padding(.vertical, Space.s12)
            }
            ForEach(symbols, id: \.self) { symbol in
                if let position = store.position(symbol) {
                    row(symbol, position)
                    Rule()
                }
            }
        }
        .sheet(item: Binding(get: { protecting.map(SymbolID.init) }, set: { protecting = $0?.id })) { item in
            ProtectPositionView(store: store, symbol: item.id).explainHost(store: store).environment(\.theme, theme)
        }
        .confirmationDialog("Flatten \(confirmFlatten ?? "")?", isPresented: Binding(get: { confirmFlatten != nil }, set: { if !$0 { confirmFlatten = nil } }), titleVisibility: .visible) {
            Button("Close at market and cancel its orders", role: .destructive) { if let s = confirmFlatten { store.flatten(s) }; confirmFlatten = nil }
        }
    }

    private func row(_ symbol: String, _ position: Position) -> some View {
        let pnl = store.unrealized(symbol)
        let today = store.todayReturn(symbol)
        return HStack(alignment: .center, spacing: Space.s12) {
            Button { onSelect(symbol) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(symbol).font(theme.label).holdToExplainSymbol(symbol)
                        Text(position.isLong ? "LONG" : "SHORT").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .foregroundStyle(.white).background(position.isLong ? theme.stockGain : theme.stockLoss, in: RoundedRectangle(cornerRadius: 3))
                    }
                    Text("\(Format.shares(position.size)) @ \(Format.money(position.averagePrice ?? 0)) · last \(market.price(symbol).map(Format.price) ?? "—")")
                        .font(theme.meta).foregroundStyle(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 3) {
                Text(pnl.map(Format.signedMoney) ?? "—").font(theme.label.monospacedDigit()).foregroundStyle(theme.gain((pnl ?? 0) >= 0))
                    .holdToExplain("On paper", value: pnl.map { Format.signedMoney($0) } ?? "—", symbol: symbol, tone: theme.gain((pnl ?? 0) >= 0))
                if let today { Text("Today \(Format.signedMoney(today))").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted).holdToExplain("Today", value: Format.signedMoney(today), term: "P&L", symbol: symbol) }
            }
            Menu {
                Button("Close position", role: .destructive) { confirmFlatten = symbol }
                Button("Reverse to \(position.isLong ? "short" : "long")") { store.reverse(symbol) }
                Button("Add stop / target…") { protecting = symbol }
                Button("Open chart") { onSelect(symbol) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Actions for \(symbol)")
        }
        .padding(.vertical, Space.s8)
    }
}

struct SymbolID: Identifiable { let id: String }

/// Working orders with cancel and price edits.
struct OrdersBlotter: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var symbol: String? = nil
    @State private var editing: PracticeOrder?
    @State private var newPrice = ""

    var body: some View {
        let orders = (symbol.map { store.workingOrders($0) } ?? store.workingOrders).sorted { $0.submittedAt > $1.submittedAt }
        VStack(alignment: .leading, spacing: 0) {
            if orders.isEmpty {
                Text("No working orders.").font(theme.label).foregroundStyle(theme.muted).padding(.vertical, Space.s12)
            }
            ForEach(orders) { order in
                HStack(spacing: Space.s12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(order.summary).font(theme.label).foregroundStyle(order.side == .buy ? theme.stockGain : theme.stockLoss)
                        HStack(spacing: 6) {
                            OrderStatusLabel(status: order.status)
                            if order.role != .entry { Text(order.role.rawValue).font(theme.meta).foregroundStyle(theme.muted) }
                            Text(order.tif.rawValue + (order.extendedHours ? " · Ext" : "")).font(theme.meta).foregroundStyle(theme.muted)
                            if let stop = order.effectiveStop, order.type == .trailingStop { Text("stop \(Format.money(stop))").font(theme.meta).foregroundStyle(theme.muted) }
                        }
                    }
                    Spacer()
                    if order.status == .open && (order.type.usesLimit || order.type == .stop) && order.triggeredAt == nil {
                        Button("Edit") {
                            editing = order
                            newPrice = Format.plain(order.type == .stop ? order.stop : order.limit)
                        }.font(theme.meta).buttonStyle(.borderless)
                    }
                    Button(role: .destructive) { store.cancel(order.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(theme.muted)
                    }.buttonStyle(.plain).accessibilityLabel("Cancel \(order.summary)")
                }
                .padding(.vertical, Space.s8)
                Rule()
            }
            if orders.count > 1 {
                Button("Cancel all", role: .destructive) { store.cancelAll(symbol) }.font(theme.meta).padding(.top, Space.s8)
            }
        }
        .alert("New price", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Price", text: $newPrice).appNumberKeyboard(.decimal)
            Button("Save") { if let order = editing, let price = DecimalInput.positive(newPrice) { store.modify(order.id, price: price) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: { Text(editing?.summary ?? "") }
    }
}

/// Today's executions.
struct FillsBlotter: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var symbol: String? = nil
    var body: some View {
        let start = store.market.hours.dayStart(Date())
        let fills = store.data.orders.filter { $0.status == .filled && ($0.filledAt ?? .distantPast) >= start && (symbol == nil || $0.symbol == symbol) }
            .sorted { ($0.filledAt ?? .distantPast) > ($1.filledAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: 0) {
            if fills.isEmpty { Text("No fills today.").font(theme.label).foregroundStyle(theme.muted).padding(.vertical, Space.s12) }
            ForEach(fills) { order in
                HStack {
                    Text(order.filledAt?.formatted(date: .omitted, time: .standard) ?? "").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
                    Text("\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol)").font(theme.label)
                        .foregroundStyle(order.side == .buy ? theme.stockGain : theme.stockLoss)
                    Spacer()
                    Text(Format.money(order.fillPrice ?? 0)).font(theme.label.monospacedDigit())
                        .holdToExplain("Fill price", value: Format.money(order.fillPrice ?? 0), symbol: order.symbol, context: ["\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol)"])
                }.padding(.vertical, 6)
                Rule()
            }
        }
    }
}

/// Best bid and offer.
struct Level1View: View {
    @Environment(\.theme) private var theme
    @ObservedObject var market: MarketData
    let symbol: String
    var body: some View {
        if let l1 = market.level1[symbol] {
            HStack(spacing: Space.s12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BID").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.muted)
                    Text("\(Format.price(l1.bid)) × \(Format.compact(l1.bidSize))").font(theme.label.monospacedDigit()).foregroundStyle(theme.stockLoss)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("SPREAD").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.muted)
                    Text(Format.price(l1.spread)).font(theme.meta.monospacedDigit()).holdToExplain("Spread", value: Format.price(l1.spread))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("ASK").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.muted)
                    Text("\(Format.price(l1.ask)) × \(Format.compact(l1.askSize))").font(theme.label.monospacedDigit()).foregroundStyle(theme.stockGain)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(market.configured ? "Waiting for an IEX quote…" : "Connect IEX in Settings for live bid/ask. Fills use a modeled spread.")
                .font(theme.meta).foregroundStyle(theme.muted)
        }
    }
}

/// Time & sales for the chart's symbol (IEX prints).
struct TapeView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var market: MarketData
    var limit = 60
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if market.tape.isEmpty {
                Text(market.configured ? "Waiting for prints…" : "Time & sales needs IEX. Connect Alpaca keys in Settings.")
                    .font(theme.meta).foregroundStyle(theme.muted).padding(.vertical, Space.s8)
            }
            ForEach(market.tape.prefix(limit)) { print in
                HStack {
                    Text(print.time.formatted(Date.FormatStyle(timeZone: market.hours.timeZone).hour(.twoDigits(amPM: .omitted)).minute().second()))
                        .foregroundStyle(theme.muted)
                    Spacer()
                    Text(Format.price(print.price))
                        .foregroundStyle(print.side == .ask ? theme.stockGain : print.side == .bid ? theme.stockLoss : theme.ink)
                    Text(Format.compact(print.size)).frame(width: 52, alignment: .trailing).foregroundStyle(print.size >= 1_000 ? theme.ink : theme.muted)
                }
                .font(.system(size: 11, weight: print.size >= 1_000 ? .semibold : .regular).monospacedDigit())
                .holdToExplain("Print", value: "\(Format.compact(print.size)) @ \(Format.price(print.price))", context: [print.side == .ask ? "Traded at the ask: a buyer paid the seller's price." : print.side == .bid ? "Traded at the bid: a seller accepted the buyer's price." : "Traded between the bid and the ask."])
                .padding(.vertical, 2)
            }
        }
    }
}

/// Attach a stop and/or target to an existing position.
struct ProtectPositionView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LabStore
    let symbol: String
    @State private var stop = ""
    @State private var target = ""
    var body: some View {
        NavigationStack {
            Form {
                if let position = store.position(symbol) {
                    Section {
                        ExplainRow("Position", value: "\(position.isLong ? "Long" : "Short") \(Format.shares(position.size)) @ \(Format.money(position.averagePrice ?? 0))", symbol: symbol)
                        ExplainRow("Last", value: store.market.price(symbol).map(Format.price) ?? "—", symbol: symbol)
                    }
                    Section {
                        TextField(position.isLong ? "Stop below the price" : "Stop above the price", text: $stop).appNumberKeyboard(.decimal)
                        TextField(position.isLong ? "Target above the price" : "Target below the price", text: $target).appNumberKeyboard(.decimal)
                    } footer: { Text("Both are good 'til canceled and cancel each other when one fills.") }
                }
            }
            .scrollContentBackground(.hidden).background(theme.paper)
            .navigationTitle("Protect \(symbol)").appInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Place") { store.protect(symbol, stop: DecimalInput.positive(stop), target: DecimalInput.positive(target)); dismiss() }
                        .disabled(DecimalInput.positive(stop) == nil && DecimalInput.positive(target) == nil)
                }
            }
        }
    }
}
