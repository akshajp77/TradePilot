import SwiftUI

// Replace the template ContentView.swift with the TradingLab folder. Supports iOS 17+ and macOS 14+.
// Your existing @main App struct can keep showing ContentView().
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = LabStore()
    @StateObject private var news = NewsStore()
    @AppStorage(PreferenceKeys.theme) private var themeName = AppTheme.botanical.rawValue
    @AppStorage(PreferenceKeys.appearance) private var appearance = "System"
    @AppStorage(PreferenceKeys.largerText) private var largerText = false
    @AppStorage(PreferenceKeys.accessibleColors) private var accessibleColors = false

    private var kind: AppTheme { AppTheme(rawValue: themeName) ?? .botanical }
    private var theme: Theme { Theme(kind: kind, accessibleColors: accessibleColors, largerText: largerText) }
    /// The feed shared by Today, News ("All relevant") and Profile.
    private var relevantSymbols: [String] { Array(Set(store.data.watched + store.heldSymbols)) }

    var body: some View {
        let theme = self.theme
        Group {
            if !store.data.onboardingComplete {
                OnboardingView(store: store, account: store.account)
                    .transition(.opacity)
            } else {
                TabView(selection: $store.tab) {
                    NavigationStack { HomeView(store: store, market: store.market) }
                        .tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
                    NavigationStack { ChartScreen(store: store, market: store.market, broker: store.broker) }
                        .tabItem { Label("Chart", systemImage: "chart.bar.xaxis") }.tag(AppTab.chart)
                    NavigationStack { ScannerView(store: store, market: store.market) }
                        .tabItem { Label("Scan", systemImage: "dot.radiowaves.left.and.right") }.tag(AppTab.scan)
                    NavigationStack { NewsView(store: store, news: news) }
                        .tabItem { Label("News", systemImage: "newspaper") }.tag(AppTab.news)
                    NavigationStack { LearnPracticeView(store: store) }
                        .learningTheme()
                        .tabItem { Label("Learn", systemImage: "book.closed") }.tag(AppTab.learn)
                }
                .tint(theme.accent)
            }
        }
        .explainHost(store: store)
        .font(theme.body)
        .foregroundStyle(theme.ink)
        .environment(\.theme, theme)
        .environmentObject(store)
        .environmentObject(news)
        .preferredColorScheme(kind.forcedScheme ?? (appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil))
        .appStockCover(item: $store.openedStock) { item in
            StockBrowserSheet(store: store, initial: item)
                .explainHost(store: store)
                .environment(\.theme, theme)
                .environmentObject(store)
                .environmentObject(news)
                .background(theme.paper.ignoresSafeArea())
        }
        .transformEnvironment(\.dynamicTypeSize) { size in if largerText && size < .xxxLarge { size = .xxxLarge } }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                ToastView(text: toast).environment(\.theme, theme)
                    .padding(.top, Space.s8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { store.dismissToast() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .animation(.easeInOut(duration: 0.6), value: store.data.onboardingComplete)
        .confirmationDialog("Three losses in a row", isPresented: $store.tiltPrompt, titleVisibility: .visible) {
            Button("Take a 15-minute break") { store.startCoolDown(minutes: 15) }
            Button("Keep trading", role: .cancel) { store.tiltPrompt = false }
        } message: {
            Text("Losing streaks happen to everyone, but they make the next trade more likely to be rushed. A short break helps you reset. You can still close positions during a break.")
        }
        .alert("Trading Lab", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.market.refresh()
                store.refreshUserFeatures()
                Task {
                    await store.account.verifyAppleCredential()
                    await store.syncNow()
                    await news.load(relevantSymbols)
                }
            case .background:
                store.flushToDisk()
                Task { await store.syncNow() }
            default: break
            }
        }
        .task { await news.load(relevantSymbols) }
        .onChange(of: relevantSymbols.sorted()) { _, symbols in Task { await news.load(symbols, force: true) } }
    }
}

/// Market session and price freshness, in one line.
struct MarketStatusLine: View {
    @Environment(\.theme) private var theme
    @ObservedObject var market: MarketData
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let (text, color) = describe(context.date)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(text).lineLimit(2)
            }
            .font(theme.meta).foregroundStyle(theme.muted)
            .accessibilityElement(children: .combine)
        }
    }

    private func describe(_ now: Date) -> (String, Color) {
        let et = TimeZone(identifier: "America/New_York")!
        func clock(_ date: Date, day: Bool = false) -> String {
            var style = Date.FormatStyle(timeZone: et).hour().minute()
            if day { style = style.weekday(.abbreviated) }
            return date.formatted(style) + " ET"
        }
        if market.feed == .offline {
            let last = market.lastPriceAt.map { " · last price \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return ("Offline\(last)", theme.warning)
        }
        switch market.hours.phase(at: now) {
        case .open(let closes):
            if let last = market.lastPriceAt, now.timeIntervalSince(last) > 20 * 60 {
                return ("Market open · prices may be stale (last update \(last.formatted(date: .omitted, time: .shortened)))", theme.warning)
            }
            return ("Market open · closes \(clock(closes))" + (market.feed == .live ? " · live IEX" : " · delayed prices"), theme.stockGain)
        case .preMarket(let opens):
            return ("Pre-market · opens \(clock(opens)) · extended-hours limit orders work now", theme.warning)
        case .afterHours(let opens):
            if market.hours.sessionKind(at: now) == .post, let session = market.hours.fullSession(on: now) {
                return ("After hours until \(clock(session.postClose)) · extended-hours limit orders work", theme.warning)
            }
            return ("Market closed · opens \(clock(opens, day: true)) · orders fill after the open", theme.muted)
        case .closed(let opens):
            return ("Market closed · opens \(clock(opens, day: true)) · orders fill after the open", theme.muted)
        }
    }
}
