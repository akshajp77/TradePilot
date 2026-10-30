import Foundation
import Combine
import UserNotifications
import WidgetKit

enum AppTab: Hashable { case home, chart, scan, news, learn }

@MainActor
final class LabStore: ObservableObject {
    let market: MarketData
    let account: AccountService
    let broker: BrokerService

    /// Views read this; change it through `mutateActive`, `updateSettings` or `replaceWorkspace`.
    /// It is settable only so LabStore's extension files (LabStore+*.swift) can update it.
    @Published var workspace: Workspace {
        didSet { workspaceDidChange(from: oldValue) }
    }
    @Published var openedStock: Security?
    /// Symbol shown on the Chart tab.
    @Published var chartSymbol: String = "SPY"
    @Published var tab: AppTab = .home
    /// Modal alert. Only for results of something the user just did that needs reading.
    @Published var notice: String?
    /// Non-blocking banner: fills, triggers, alerts, schedules.
    @Published private(set) var toast: String?
    /// Set by LabStore+Sync.swift.
    @Published var syncStatus = "Not signed in"
    @Published var isSyncing = false
    /// The bar-replay sandbox, while one is running.
    @Published var replay: ReplaySession?
    @Published var replayLoading = false
    /// Set after a third straight loss; the UI offers a short break.
    @Published var tiltPrompt = false

    var stockBrowseOrder: [String] = []
    let liveServices: Bool

    // Store internals. Not private only because LabStore+*.swift files share them; views shouldn't use them.
    let file: WorkspaceFile
    let defaults: UserDefaults
    private var ledgerCache: Ledger?
    private var tripsCache: [RoundTrip]?
    var pendingSymbols: Set<String> = []
    var saveTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    var clockTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    var vwapSide: [String: Bool] = [:]
    /// Local edits since launch; compared with `syncedChange` to know whether the server is behind.
    var localChange = 0
    var syncedChange = 0
    private var suppressSyncTrigger = false
    var syncAgain = false

    private static let revisionKey = "trading-lab-sync-revision-v2"
    var revision: Int? {
        get { defaults.object(forKey: Self.revisionKey) as? Int }
        set { defaults.set(newValue, forKey: Self.revisionKey) }
    }

    init(file: WorkspaceFile = WorkspaceFile(), defaults: UserDefaults = .standard, connectMarket: Bool = true,
         market: MarketData? = nil, account: AccountService? = nil, broker: BrokerService? = nil) {
        self.file = file
        self.defaults = defaults
        self.liveServices = connectMarket
        self.market = market ?? MarketData()
        self.account = account ?? AccountService()
        self.broker = broker ?? BrokerService()

        var migratedLegacySync = false
        if let saved = file.load() {
            workspace = saved
        } else if let migrated = LegacyMigration.migrate(from: defaults) {
            workspace = migrated
            migratedLegacySync = defaults.string(forKey: "trading-lab-site-url") != nil
        } else {
            workspace = .fresh()
        }
        if let data = try? WorkspaceCodec.encode(workspace), (try? file.writeNow(data)) != nil {
            LegacyMigration.markDone(defaults)
            for key in [LegacyMigration.accountKey, LegacyMigration.historyKey, LegacyMigration.featureKey, LegacyMigration.customKey,
                        "trading-lab-site-revision", "trading-lab-site-url", "trading-lab-starting-balance-v2"] {
                defaults.removeObject(forKey: key)
            }
        }
        if connectMarket { Keychain.deleteLegacyRecoveryKey() }
        chartSymbol = workspace.portfolios[workspace.activeIndex].account.watched.first ?? "SPY"

        rebuildCaches()
        self.market.onQuote = { [weak self] symbol, quote in self?.handle(symbol: symbol, quote: quote) }
        self.market.onBars = { [weak self] symbol in self?.evaluateIndicatorAlerts(symbol: symbol) }
        self.market.setTracked(allSecurities, reconnect: false)
        self.market.objectWillChange
            .receive(on: RunLoop.main)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.recordPortfolio() }
            .store(in: &cancellables)
        self.account.$signedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in self?.accountChanged(signedIn) }
            .store(in: &cancellables)

        if connectMarket {
            self.market.connect()
            startClock()
            loadAlertBars()
            if migratedLegacySync { showToast("Sync now uses Sign in with Apple. Sign in from Settings to keep syncing.") }
        }
    }

    // MARK: Workspace access

    var data: AccountData {
        get { workspace.portfolios[workspace.activeIndex].account }
        set { mutateActive { $0 = newValue } }
    }

    var features: UserFeatures {
        get { workspace.features }
        set { workspace.features = newValue }
    }

    var settings: TradingSettings { data.settings }
    var portfolioHistory: [PortfolioSample] { workspace.portfolios[workspace.activeIndex].history }
    var portfolios: [Portfolio] { workspace.portfolios }
    var activePortfolioID: String { workspace.activePortfolioID }
    var activeTitle: String { workspace.portfolios[workspace.activeIndex].title }
    var customSecurities: [Security] { workspace.customSecurities }
    var allSecurities: [Security] { MarketCatalog.securities + workspace.customSecurities }
    func security(_ symbol: String) -> Security? { allSecurities.first { $0.symbol == symbol } }

    /// Edits the active account; bumps its `updatedAt` when synced scalar fields change.
    /// For extensions in other files (the setter is private to this file).
    func replaceWorkspace(_ updated: Workspace) { workspace = updated }

    func mutateActive(_ change: (inout AccountData) -> Void) {
        let index = workspace.activeIndex
        var account = workspace.portfolios[index].account
        let before = (account.name, account.goal, account.watched, account.initialBalance, account.settings)
        change(&account)
        if before != (account.name, account.goal, account.watched, account.initialBalance, account.settings) { account.updatedAt = Date() }
        workspace.portfolios[index].account = account
    }

    func updateSettings(_ change: (inout TradingSettings) -> Void) {
        mutateActive { change(&$0.settings) }
    }

    private func workspaceDidChange(from old: Workspace) {
        rebuildCaches()
        scheduleSave()
        if old.customSecurities != workspace.customSecurities { market.setTracked(allSecurities) }
        if !suppressSyncTrigger {
            localChange += 1
            scheduleSync()
        }
    }

    private func rebuildCaches() {
        ledgerCache = nil
        tripsCache = nil
        pendingSymbols = Set(workspace.portfolios.flatMap { $0.account.orders.filter { $0.status.isWorking }.map(\.symbol) })
    }

    func quietly(_ work: () -> Void) {
        let previous = suppressSyncTrigger
        suppressSyncTrigger = true
        work()
        suppressSyncTrigger = previous
    }

    // MARK: Ledger-derived values (Decimal)

    var ledger: Ledger {
        if let ledgerCache { return ledgerCache }
        let built = Ledger(data)
        ledgerCache = built
        return built
    }

    var cash: Decimal { ledger.cash }
    /// Signed quantity (negative = short).
    func shares(_ symbol: String) -> Decimal { ledger.shares(symbol) }
    func position(_ symbol: String) -> Position? { ledger.position(symbol) }
    var heldSymbols: [String] { ledger.heldSymbols }
    func costBasis(_ symbol: String) -> Decimal? { ledger.costBasis(symbol) }
    var startingBalance: Decimal { data.initialBalance }
    var workingOrders: [PracticeOrder] { data.orders.filter { $0.status.isPending } }
    func workingOrders(_ symbol: String) -> [PracticeOrder] { data.orders.filter { $0.symbol == symbol && $0.status.isPending } }

    var pricesReady: Bool { ledger.heldSymbols.allSatisfy { market.price($0) != nil } }
    var portfolioValue: Decimal? { ledger.value { self.market.decimalPrice($0) } }

    var margin: MarginSnapshot? {
        Margin.snapshot(account: data, ledger: ledger, price: { self.market.decimalPrice($0) }, now: Date())
    }
    var availableBuyingPower: Decimal { margin?.availableBuyingPower ?? max(0, cash) }

    /// Long shares not already committed to working sell orders.
    func availableShares(_ symbol: String) -> Decimal {
        let long = max(0, shares(symbol))
        let committed = workingOrders(symbol).filter { $0.side == .sell && $0.status.isWorking && $0.parentID == nil }.reduce(Decimal(0)) { $0 + $1.shares }
        return max(0, long - committed)
    }

    func positionValue(_ symbol: String) -> Decimal? {
        market.decimalPrice(symbol).map { (shares(symbol) * $0).rounded(Precision.cash) }
    }

    func unrealized(_ symbol: String) -> Decimal? {
        guard let position = position(symbol), let price = market.decimalPrice(symbol) else { return nil }
        return position.unrealized(price)
    }

    func todayReturn(_ symbol: String) -> Decimal? {
        guard let price = market.decimalPrice(symbol) else { return nil }
        return DayPnL.symbol(symbol, account: data, price: price, previousClose: market.decimalPreviousClose(symbol), now: Date(), hours: market.hours)
    }

    func totalReturn(_ symbol: String) -> Decimal? { unrealized(symbol) }

    var dayPnL: Decimal? {
        DayPnL.account(data, price: { self.market.decimalPrice($0) }, previousClose: { self.market.decimalPreviousClose($0) },
                       now: Date(), hours: market.hours)
    }

    var dayRealized: Decimal {
        let start = market.hours.dayStart(Date())
        return ledger.realized.filter { $0.date >= start }.reduce(0) { $0 + $1.gain - $1.fees }
    }

    var isLockedOut: Bool {
        guard let limit = settings.dailyLossLimit, limit > 0, let day = dayPnL else { return false }
        return day <= -limit
    }

    var roundTrips: [RoundTrip] {
        if let tripsCache { return tripsCache }
        let built = TradeAnalytics.roundTrips(data, notes: workspace.features.tradeNotes)
        tripsCache = built
        return built
    }

    var todaysTrips: [RoundTrip] {
        let start = market.hours.dayStart(Date())
        return roundTrips.filter { ($0.exitTime ?? $0.entryTime) >= start }
    }

    func context(now: Date = Date()) -> MarketContext {
        MarketContext(price: { self.market.decimalPrice($0) }, dayPnL: dayPnL, now: now, hours: market.hours)
    }

    // MARK: Messages

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    func openStock(_ item: Security, order: [String]? = nil) {
        let requested = order ?? data.watched
        var seen = Set<String>()
        stockBrowseOrder = requested.filter { security($0) != nil && seen.insert($0).inserted }
        if !stockBrowseOrder.contains(item.symbol) { stockBrowseOrder.append(item.symbol) }
        openedStock = item
    }
}
