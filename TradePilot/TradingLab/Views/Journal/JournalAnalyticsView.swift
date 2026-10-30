import SwiftUI
import Charts

/// Trade journal analytics: what works, what doesn't, by setup, time and hold.
struct JournalAnalyticsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var period: Period = .month
    @State private var grouping: TradeAnalytics.Grouping = .setup
    @State private var month = Date()
    @State private var sharing = false

    enum Period: String, CaseIterable { case today = "Today", week = "Week", month = "Month", all = "All" }

    private var hours: MarketHours { store.market.hours }

    private var trips: [RoundTrip] {
        let all = store.roundTrips.filter { !$0.isOpen }
        let now = Date()
        let start: Date
        switch period {
        case .today: start = hours.dayStart(now)
        case .week: start = hours.calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: start = hours.calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .all: return all
        }
        return all.filter { ($0.exitTime ?? $0.entryTime) >= start }
    }

    var body: some View {
        let trips = self.trips
        let stats = TradeAnalytics.stats(trips)
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                Picker("Period", selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                if trips.isEmpty {
                    Text(store.roundTrips.isEmpty
                         ? "No closed trades yet. Trades appear here when a position goes back to flat."
                         : "No closed trades in this period.")
                        .font(theme.label).foregroundStyle(theme.muted)
                } else {
                    summary(stats)
                    equityCurve(trips)
                }
                PnLCalendar(daily: TradeAnalytics.dailyPnL(store.roundTrips, hours: hours), month: $month, hours: hours)
                if !trips.isEmpty {
                    breakdown(trips)
                    tradeList(trips)
                }
                if !store.features.barReplays.isEmpty {
                    NavigationLink { ReplayHomeView(store: store) } label: {
                        Text("\(store.features.barReplays.count) bar replay sessions →").font(theme.label)
                    }
                }
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: store.tradesCSV, preview: SharePreview("Trading Lab trades.csv")) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export trades as CSV")
            }
        }
    }

    // MARK: Sections

    private func summary(_ stats: TradeStats) -> some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Net P&L · \(stats.trades) trades")
                Text(Format.signedMoney(stats.netPnL)).font(theme.display).monospacedDigit()
                    .foregroundStyle(theme.gain(stats.netPnL >= 0)).minimumScaleFactor(0.7).lineLimit(1)
                    .holdToExplain("Net P&L", value: Format.signedMoney(stats.netPnL), context: ["Across \(stats.trades) trades, after commissions."], tone: theme.gain(stats.netPnL >= 0))
                if stats.fees > 0 { Text("After \(Format.money(stats.fees)) in commissions").font(theme.meta).foregroundStyle(theme.muted) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: Space.s16) {
                cell("Win rate", stats.winRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—",
                     help: "Share of closed trades that made money after fees.")
                cell("Profit factor", stats.profitFactor.map { String(format: "%.2f", $0) } ?? (stats.grossProfit > 0 ? "∞" : "—"),
                     help: "Gross profit ÷ gross loss. Above 1 means winners outweigh losers.")
                cell("Expectancy", stats.expectancy.map(Format.signedMoney) ?? "—", help: "Average net P&L per trade.")
                cell("Avg win", stats.averageWin.map(Format.money) ?? "—")
                cell("Avg loss", stats.averageLoss.map(Format.money) ?? "—")
                cell("Avg R", stats.averageR.map { String(format: "%+.2fR", $0) } ?? "—", help: "Average result in units of planned risk. Needs a stop on entry.")
                cell("Largest win", Format.money(stats.largestWin))
                cell("Largest loss", Format.money(stats.largestLoss))
                cell("Max drawdown", Format.money(stats.maxDrawdown), help: "Largest fall from a peak in cumulative P&L.")
                cell("Hold (wins)", stats.averageHoldWin.map(duration) ?? "—")
                cell("Hold (losses)", stats.averageHoldLoss.map(duration) ?? "—",
                     warn: (stats.averageHoldLoss ?? 0) > (stats.averageHoldWin ?? .infinity),
                     help: "If losers are held longer than winners, you may be cutting winners early and hoping on losers.")
                cell("Loss streak", "\(stats.maxConsecutiveLosses)")
            }
        }
    }

    private static let terms = ["Win rate": "Win rate", "Profit factor": "Profit factor", "Expectancy": "Expectancy", "Avg R": "R-multiple", "Max drawdown": "Drawdown"]

    private func cell(_ label: String, _ value: String, warn: Bool = false, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 1) {
                Text(label).font(theme.meta).foregroundStyle(theme.muted).lineLimit(1)
                if let term = Self.terms[label] { ExplainButton(term: term, size: 10) }
            }
            Text(value).font(theme.label.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(warn ? theme.loss : theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? label)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help ?? "")
    }

    private func equityCurve(_ trips: [RoundTrip]) -> some View {
        let curve = TradeAnalytics.equityCurve(trips)
        return VStack(alignment: .leading, spacing: Space.s8) {
            Text("Cumulative P&L").font(theme.section)
            Chart {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(theme.line)
                ForEach(Array(curve.enumerated()), id: \.offset) { index, point in
                    LineMark(x: .value("Trade", index + 1), y: .value("P&L", point.value.double))
                        .foregroundStyle(theme.accent).interpolationMethod(.linear)
                    AreaMark(x: .value("Trade", index + 1), y: .value("P&L", point.value.double))
                        .foregroundStyle(theme.accent.opacity(0.08))
                }
            }
            .chartXAxisLabel("Trade #")
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text(Format.compact(v)) } } } }
            .frame(height: 180)
            .accessibilityLabel("Cumulative P&L over \(curve.count) trades, ending at \(Format.signedMoney(curve.last?.value ?? 0))")
        }
    }

    private func breakdown(_ trips: [RoundTrip]) -> some View {
        let rows = TradeAnalytics.breakdown(trips, by: grouping, hours: hours)
        let maxAbs = rows.map { abs($0.stats.netPnL.double) }.max() ?? 1
        return VStack(alignment: .leading, spacing: Space.s12) {
            HStack {
                Text("Breakdown").font(theme.section)
                Spacer()
                Picker("Group by", selection: $grouping) { ForEach(TradeAnalytics.Grouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
            }
            ForEach(rows, id: \.key) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.key).font(theme.label)
                        Spacer()
                        Text(Format.signedMoney(row.stats.netPnL)).font(theme.label.monospacedDigit()).foregroundStyle(theme.gain(row.stats.netPnL >= 0))
                            .holdToExplain("Net P&L", value: Format.signedMoney(row.stats.netPnL), context: ["For \(row.key)."], tone: theme.gain(row.stats.netPnL >= 0))
                    }
                    GeometryReader { geometry in
                        let width = geometry.size.width * CGFloat(abs(row.stats.netPnL.double) / max(maxAbs, 0.01))
                        RoundedRectangle(cornerRadius: 2).fill(theme.gain(row.stats.netPnL >= 0).opacity(0.7)).frame(width: max(2, width), height: 6)
                    }.frame(height: 6)
                    Text("\(row.stats.trades) trades · \(row.stats.winRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—") win · PF \(row.stats.profitFactor.map { String(format: "%.2f", $0) } ?? "—")")
                        .font(theme.meta).foregroundStyle(theme.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func tradeList(_ trips: [RoundTrip]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trades").font(theme.section).padding(.bottom, Space.s8)
            ForEach(trips.sorted { ($0.exitTime ?? $0.entryTime) > ($1.exitTime ?? $1.entryTime) }) { trip in
                NavigationLink { TradeDetailView(store: store, trip: trip) } label: { TripRow(trip: trip) }.buttonStyle(.plain)
                Rule()
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }
}

struct TripRow: View {
    @Environment(\.theme) private var theme
    let trip: RoundTrip
    var body: some View {
        HStack(spacing: Space.s12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(trip.symbol).font(theme.label)
                    Text(trip.isLong ? "LONG" : "SHORT").font(.system(size: 9, weight: .bold)).foregroundStyle(trip.isLong ? theme.stockGain : theme.stockLoss)
                    if trip.setup != "Uncategorized" { Text(trip.setup).font(theme.meta).foregroundStyle(theme.muted) }
                }
                Text("\(Format.shares(trip.quantity)) · \(Format.money(trip.averageEntry)) → \(trip.averageExit.map(Format.money) ?? "—") · \((trip.exitTime ?? trip.entryTime).formatted(date: .abbreviated, time: .shortened))")
                    .font(theme.meta).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.signedMoney(trip.netPnL)).font(theme.label.monospacedDigit()).foregroundStyle(theme.gain(trip.netPnL >= 0))
                    .holdToExplain("Net P&L", value: Format.signedMoney(trip.netPnL), symbol: trip.symbol, context: ["This one trade, after commissions."], tone: theme.gain(trip.netPnL >= 0))
                if let r = trip.rMultiple { Text(String(format: "%+.2fR", r)).font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted) }
            }
        }
        .padding(.vertical, Space.s8).contentShape(Rectangle())
    }
}

/// Month grid of daily net P&L.
struct PnLCalendar: View {
    @Environment(\.theme) private var theme
    let daily: [Date: Decimal]
    @Binding var month: Date
    let hours: MarketHours

    var body: some View {
        let calendar = hours.calendar
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let values = (0..<days).map { offset -> (Date, Decimal?) in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return (date, daily[hours.dayStart(date)])
        }
        let monthTotal = values.compactMap(\.1).reduce(0, +)
        let maxAbs = values.compactMap { $0.1.map { abs($0.double) } }.max() ?? 1
        VStack(alignment: .leading, spacing: Space.s8) {
            HStack {
                Text("P&L calendar").font(theme.section)
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Text(start.formatted(.dateTime.month(.abbreviated).year())).font(theme.label).frame(minWidth: 80)
                Button { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    Text(calendar.veryShortWeekdaySymbols[(i + calendar.firstWeekday - 1) % 7]).font(.system(size: 10)).foregroundStyle(theme.muted)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(values, id: \.0) { date, value in
                    let intensity = value.map { min(1, abs($0.double) / max(maxAbs, 0.01)) } ?? 0
                    VStack(spacing: 1) {
                        Text("\(calendar.component(.day, from: date))").font(.system(size: 10)).foregroundStyle(theme.muted)
                        if let value { Text(Format.compact(value.double)).font(.system(size: 9, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background((value.map { theme.gain($0 >= 0) } ?? theme.line).opacity(value == nil ? 0.15 : 0.15 + 0.55 * intensity),
                                in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted)): \(value.map(Format.signedMoney) ?? "no trades")")
                }
            }
            Text("Month: \(Format.signedMoney(monthTotal)) · \(values.filter { ($0.1 ?? 0) > 0 }.count) green days, \(values.filter { ($0.1 ?? 0) < 0 }.count) red")
                .font(theme.meta).foregroundStyle(theme.muted)
        }
    }
}

/// One round trip on its chart, with fills, plan and reflection.
struct TradeDetailView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    let trip: RoundTrip
    @State private var timeframe: Timeframe = .m5
    @State private var tool: DrawingTool?
    @State private var reflection = ""

    private var fills: [PracticeOrder] { store.data.orders.filter { trip.fillIDs.contains($0.id) }.sorted { ($0.filledAt ?? .distantPast) < ($1.filledAt ?? .distantPast) } }
    private var entry: PracticeOrder? { store.data.orders.first { $0.id == trip.id } }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "\(trip.isLong ? "Long" : "Short") · \(trip.setup)")
                    Text(Format.signedMoney(trip.netPnL)).font(theme.display).monospacedDigit().foregroundStyle(theme.gain(trip.netPnL >= 0))
                        .holdToExplain("Net P&L", value: Format.signedMoney(trip.netPnL), symbol: trip.symbol, context: ["This one trade, after commissions."], tone: theme.gain(trip.netPnL >= 0))
                    Text("\(trip.symbol) · \(Format.shares(trip.quantity)) shares · \(Format.money(trip.averageEntry)) → \(trip.averageExit.map(Format.money) ?? "—")")
                        .font(theme.label).foregroundStyle(theme.muted)
                    if let r = trip.rMultiple { Text(String(format: "%+.2fR on planned risk", r)).font(theme.meta).foregroundStyle(theme.muted) }
                }
                TradeReviewCard(trip: trip, review: store.review(trip))
                chart
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fills").font(theme.section).padding(.bottom, Space.s8)
                    ForEach(fills) { order in
                        HStack {
                            Text(order.filledAt?.formatted(date: .omitted, time: .standard) ?? "").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
                            Text("\(order.side.rawValue) \(Format.shares(order.shares))").foregroundStyle(order.side == .buy ? theme.stockGain : theme.stockLoss)
                            Text(order.type.rawValue).font(theme.meta).foregroundStyle(theme.muted)
                            Spacer()
                            Text(Format.money(order.fillPrice ?? 0)).monospacedDigit()
                        }.font(theme.label).padding(.vertical, 6)
                        Rule()
                    }
                }
                if let entry, !(entry.thesis.isEmpty && entry.invalidation.isEmpty) {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text("Plan").font(theme.section)
                        if !entry.thesis.isEmpty { Text(entry.thesis) }
                        if !entry.invalidation.isEmpty { Text("Wrong if: \(entry.invalidation)").foregroundStyle(theme.muted) }
                        if let stop = trip.plannedStop { Text("Planned stop \(Format.money(stop))").font(theme.meta).foregroundStyle(theme.muted) }
                    }
                }
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Review").font(theme.section)
                    Picker("Setup", selection: Binding(get: { note.strategy }, set: { var n = note; n.strategy = $0; store.setNote(n, for: trip.id) })) {
                        ForEach(TradeNote.strategies, id: \.self) { Text($0) }
                    }
                    Picker("Emotion", selection: Binding(get: { note.emotion }, set: { var n = note; n.emotion = $0; store.setNote(n, for: trip.id) })) {
                        ForEach(TradeNote.emotions, id: \.self) { Text($0) }
                    }
                    Picker("Followed the plan?", selection: Binding(get: { note.followedPlan }, set: { var n = note; n.followedPlan = $0; store.setNote(n, for: trip.id) })) {
                        Text("Not set").tag(Bool?.none); Text("Yes").tag(Bool?.some(true)); Text("No").tag(Bool?.some(false))
                    }
                    TextField("What did you learn?", text: $reflection, axis: .vertical).lineLimit(3...8).inputField()
                        .onChange(of: reflection) { _, text in store.reflect(trip.id, text: text) }
                }
            }
        }
        .navigationTitle(trip.symbol).appInlineTitle()
        .task {
            reflection = entry?.reflection ?? ""
            let age = Date().timeIntervalSince(trip.entryTime)
            timeframe = age < 4 * 86_400 ? .m1 : age < 25 * 86_400 ? .m5 : age < 150 * 86_400 ? .h1 : .d1
            await store.market.loadBars(trip.symbol, timeframe: timeframe)
        }
    }

    private var note: TradeNote { store.features.tradeNotes[trip.id.uuidString] ?? TradeNote() }

    @ViewBuilder private var chart: some View {
        let bars = store.market.candles(trip.symbol, timeframe)
        let start = trip.entryTime.addingTimeInterval(-timeframe.seconds * 40)
        let end = (trip.exitTime ?? Date()).addingTimeInterval(timeframe.seconds * 40)
        let window = bars.filter { $0.time >= start && $0.time <= end }
        if window.count >= 5 {
            ProChartView(data: .build(bars: window, timeframe: timeframe, preferences: store.chartPreferences, previousClose: nil, hours: store.market.hours),
                         style: .candles, showVolume: true, resetKey: "trip-\(trip.id)",
                         executions: fills.compactMap { o in o.filledAt.flatMap { t in o.fillPrice.map { ChartExecution(time: t, price: $0.double, side: o.side) } } },
                         tool: $tool)
                .frame(height: 300)
        } else if store.market.isLoading(trip.symbol, timeframe: timeframe) {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Text("Intraday bars for this trade are no longer available from the data source (1-minute bars cover about 5 sessions, 5-minute about a month).")
                .font(theme.meta).foregroundStyle(theme.muted)
        }
    }
}
