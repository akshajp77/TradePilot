import SwiftUI

/// Home: today's P&L, risk, positions and orders first; markets and tools below.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var news: NewsStore
    @ObservedObject var store: LabStore
    /// Not observed here: only the subviews that show prices redraw on ticks.
    let market: MarketData
    @State private var confirmFlattenAll = false

    var body: some View {
        Page(mainAtmosphere: true) {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: Space.s8) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        HStack(alignment: .firstTextBaseline) {
                            Text("Trading Lab").font(theme.section).tracking(-0.5)
                            Spacer()
                            Text(context.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(theme.meta).foregroundStyle(theme.muted)
                        }
                    }
                    MarketStatusLine(market: market)
                }
                PortfolioSwitcher(store: store)
                DayHero(store: store, market: market)
                QuickLaunch(store: store)
                CoachCards(store: store, broker: store.broker)
                Rule()
                VStack(alignment: .leading, spacing: Space.s8) {
                    HStack {
                        Text("Positions").font(theme.section).tracking(-0.3)
                        Spacer()
                        if !store.heldSymbols.isEmpty {
                            Button("Close all", role: .destructive) { confirmFlattenAll = true }.font(theme.meta.weight(.semibold))
                                .foregroundStyle(theme.loss)
                        }
                    }
                    PositionsBlotter(store: store, market: store.market) { store.openChart($0) }
                }
                let orders = store.workingOrders
                if !orders.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        HStack { Text("Working orders").font(theme.section).tracking(-0.3); Spacer(); Text("\(orders.count)").font(theme.meta).foregroundStyle(theme.muted) }
                        OrdersBlotter(store: store)
                    }
                }
                AccountValueSection(store: store, market: store.market)
                Rule()
                WatchlistSection(store: store, market: market)
                Rule()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Markets").font(theme.section)
                        Spacer()
                        NavigationLink { StockFinderView(store: store) } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 19)).frame(width: 44, height: 44)
                        }.accessibilityLabel("Find a stock or fund")
                    }.padding(.bottom, Space.s8)
                    ForEach(store.allSecurities) { item in MarketRow(item: item, market: market) }
                    MarketFeedStatus(market: market).padding(.top, Space.s12)
                }
                TodayTools(store: store)
            }
        }
        .refreshable {
            store.market.refresh()
            await news.load(Array(Set(store.data.watched + store.heldSymbols)), force: true)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { ProfileView(store: store, news: news, account: store.account) } label: {
                    Image(systemName: "person.crop.circle").font(.system(size: 20))
                }.accessibilityLabel("Profile and settings")
            }
        }
        .confirmationDialog("Close every practice position?", isPresented: $confirmFlattenAll, titleVisibility: .visible) {
            Button("Close all at market and cancel orders", role: .destructive) { store.flattenAll() }
        } message: { Text("Market orders for \(store.heldSymbols.joined(separator: ", ")).") }
    }
}

private struct MarketFeedStatus: View {
    @Environment(\.theme) private var theme
    @ObservedObject var market: MarketData
    var body: some View { Text(market.statusText).font(theme.meta).foregroundStyle(theme.muted) }
}

/// Day P&L, equity, buying power and the risk guardrails. Redraws on ticks.
private struct DayHero: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData

    var body: some View {
        let day = store.dayPnL
        let equity = store.portfolioValue
        let trips = store.todaysTrips.filter { !$0.isOpen }
        let stats = TradeAnalytics.stats(trips)
        let unrealized = store.heldSymbols.compactMap { store.unrealized($0) }.reduce(0, +)
        VStack(alignment: .leading, spacing: Space.s16) {
            VStack(alignment: .leading, spacing: Space.s8) {
                HStack(spacing: 2) { Eyebrow(text: "Today's profit or loss"); ExplainButton(term: "P&L", size: 12) }
                AnimatedMoney(value: day?.double, placeholder: "Waiting for prices", font: theme.display, showPlus: true)
                    .tracking(-1.3).minimumScaleFactor(0.72).lineLimit(1)
                    .foregroundStyle(theme.gain((day ?? 0) >= 0))
                    .holdToExplain("Today's profit or loss", value: day.map { Format.signedMoney($0) } ?? "Waiting for prices", tone: theme.gain((day ?? 0) >= 0))
                HStack(spacing: Space.s12) {
                    Text("Locked in \(Format.signedMoney(store.dayRealized))").holdToExplain("Locked in", value: Format.signedMoney(store.dayRealized))
                    Text("On paper \(Format.signedMoney(unrealized))").holdToExplain("On paper", value: Format.signedMoney(unrealized))
                    ExplainButton(term: "Unrealized return", size: 11)
                    Spacer()
                }.font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
            }
            if store.isLockedOut {
                Label("Daily loss limit hit. New positions are locked until the next session; you can still close and reduce.", systemImage: "lock.fill")
                    .font(theme.meta).foregroundStyle(.white).padding(Space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.loss, in: RoundedRectangle(cornerRadius: Space.smallRadius))
            } else if let limit = store.settings.dailyLossLimit, limit > 0 {
                let used = max(0, min(1, (-(day ?? 0) / limit).double))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Daily loss limit").font(theme.meta)
                        Spacer()
                        Text("\(Format.money(max(0, limit + (day ?? 0)))) left of \(Format.money(limit))").font(theme.meta.monospacedDigit())
                    }.foregroundStyle(theme.muted)
                    ProgressView(value: used).tint(used > 0.75 ? theme.loss : used > 0.4 ? theme.warning : theme.accent)
                }
            }
            if let margin = store.margin, margin.hasDeficit {
                Label("Margin call: equity \(Format.money(margin.equity)) is below the \(Format.money(margin.maintenanceRequirement)) maintenance requirement. Reduce positions.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(theme.meta).foregroundStyle(theme.loss)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: Space.s16) {
                stat("Account value", equity.map(Format.money) ?? "—", term: "Equity")
                stat("Can spend", Format.money(store.availableBuyingPower), term: "Buying power")
                stat("Cash", Format.money(store.cash))
                stat("Trades today", "\(stats.trades)")
                stat("Winners", stats.winRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                if store.settings.regime == .legacyPDT && store.settings.accountType == .margin {
                    let count = store.ledger.dayTradeCount(asOf: Date())
                    stat("Day trades this week", "\(count) of 3", warn: count >= 3 && (equity ?? 0) < TradingSettings.legacyPDTEquity, term: "Pattern day trader rule")
                } else {
                    stat("Invested vs account", store.margin.map { m in m.equity > 0 ? String(format: "%.2fx", ((m.longValue + m.shortValue) / m.equity).double) : "—" } ?? "—", term: "Leverage")
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, warn: Bool = false, term: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 1) {
                Text(label).font(theme.meta).foregroundStyle(theme.muted).lineLimit(1)
                if let term { ExplainButton(term: term, size: 10) }
            }
            Text(value).font(theme.label.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(warn ? theme.loss : theme.ink)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One-tap entry points for the trading workflow.
private struct QuickLaunch: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var body: some View {
        HStack(spacing: Space.s8) {
            tile("Chart", "chart.bar.xaxis") { store.tab = .chart }
            tile("Scanner", "dot.radiowaves.left.and.right") { store.tab = .scan }
            NavigationLink { ReplayHomeView(store: store) } label: { tileLabel("Replay", "backward.end.alt") }.buttonStyle(.plain)
            NavigationLink { JournalAnalyticsView(store: store) } label: { tileLabel("Journal", "chart.pie") }.buttonStyle(.plain)
        }
    }
    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }.buttonStyle(.plain)
    }
    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(theme.accent)
            Text(title).font(theme.meta).foregroundStyle(theme.ink)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        .overlay(RoundedRectangle(cornerRadius: Space.radius).stroke(theme.line, lineWidth: 1))
    }
}

/// Account value over time, collapsed by default.
private struct AccountValueSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @State private var range: ChartRange = .month
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Space.s12) {
                InteractiveLineChart(points: store.portfolioHistory.filter { $0.date >= range.start() }.map { PricePoint(date: $0.date, price: $0.value) },
                                     baseline: store.startingBalance.double, title: "Account value", range: $range)
                    .id(range)
                if let value = store.portfolioValue {
                    let gain = value - store.startingBalance
                    Text("\(Format.signedMoney(gain)) since the \(Format.money(store.startingBalance)) start")
                        .font(theme.meta).foregroundStyle(theme.gain(gain >= 0))
                }
            }.padding(.top, Space.s8)
        } label: {
            HStack {
                Text("Account value").font(theme.section).tracking(-0.3)
                Spacer()
                Text(store.portfolioValue.map(Format.money) ?? "—").font(theme.label.monospacedDigit()).foregroundStyle(theme.muted)
            }
        }
    }
}

/// Coaching on Home: what to learn next, the last trade's grade, this week's fix, and the real account.
private struct CoachCards: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var broker: BrokerService

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if store.isCoolingDown, let until = store.learning.coolDownUntil {
                HStack {
                    Label("On a break until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "cup.and.saucer.fill").font(theme.label)
                    Spacer()
                    Button("End break") { store.endCoolDown() }.font(theme.meta)
                }
                .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
            }
            if let next = store.nextPathLesson {
                NavigationLink { PathLessonView(store: store, lesson: next).learningTheme() } label: {
                    HStack(spacing: Space.s12) {
                        Image(systemName: "graduationcap.fill").font(.system(size: 20)).foregroundStyle(theme.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next lesson · \(next.minutes) min").font(theme.meta).foregroundStyle(theme.muted)
                            Text(next.title).font(theme.label)
                        }
                        Spacer()
                        Text("\(store.pathProgress.done)/\(store.pathProgress.total)").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
                    }
                    .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                }.buttonStyle(.plain)
            }
            if let last = store.lastReview {
                NavigationLink { TradeDetailView(store: store, trip: last.trip) } label: {
                    TradeReviewCard(trip: last.trip, review: last.review, compact: true)
                }.buttonStyle(.plain)
            }
            if store.roundTrips.contains(where: { !$0.isOpen }) {
                NavigationLink { WeeklyReportView(store: store).learningTheme() } label: {
                    HStack(spacing: Space.s12) {
                        Image(systemName: "list.clipboard").font(.system(size: 20)).foregroundStyle(theme.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This week's tip").font(theme.meta).foregroundStyle(theme.muted)
                            Text(store.weeklyReport.fix).font(theme.label).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                }.buttonStyle(.plain)
            }
            if broker.isConnected {
                NavigationLink { LiveAccountView(store: store, broker: broker) } label: {
                    HStack(spacing: Space.s12) {
                        Image(systemName: broker.isLive ? "dollarsign.circle.fill" : "testtube.2").font(.system(size: 20))
                            .foregroundStyle(broker.isLive ? theme.loss : theme.warning).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(broker.isLive ? "Real-money account (Alpaca)" : "Alpaca paper account").font(theme.meta).foregroundStyle(theme.muted)
                            Text(broker.account.map { "\(Format.money($0.equity)) · \(Format.signedMoney($0.dayChange)) today" } ?? "Loading…").font(theme.label.monospacedDigit())
                        }
                        Spacer()
                    }
                    .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                }
                .buttonStyle(.plain)
                .task { await broker.refresh() }
            }
        }
    }
}
