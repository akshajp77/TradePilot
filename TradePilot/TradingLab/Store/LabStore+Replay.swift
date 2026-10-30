import Foundation

/// Bar replay: trading a past session one bar at a time.
extension LabStore {
    // MARK: Bar replay

    /// Loads a past session and starts a sandbox replay. 1-minute bars cover the last 5 sessions;
    /// 5-minute bars the last month.
    func startReplay(symbol: String, day: Date, timeframe: Timeframe) async {
        replayLoading = true
        defer { replayLoading = false }
        await market.loadBars(symbol, timeframe: timeframe, force: true)
        let bars = market.candles(symbol, timeframe)
        let session = ReplaySession(symbol: symbol, timeframe: timeframe, bars: bars, day: day,
                                    startingBalance: 25_000, settings: settings, revealFirst: timeframe == .m1 ? 5 : 1, hours: market.hours)
        guard !session.sessionBars.isEmpty else {
            notice = "No \(timeframe.rawValue) bars for \(symbol) on \(day.formatted(date: .abbreviated, time: .omitted)). Pick a recent session."
            return
        }
        replay = session
    }

    /// Session days that have bars for replay, newest first.
    func replayDays(symbol: String, timeframe: Timeframe) -> [Date] {
        let hours = market.hours
        let days = Set(market.candles(symbol, timeframe).filter { hours.isRegularSessionPrint($0.time) }.map { hours.dayStart($0.time) })
        let today = hours.dayStart(Date())
        return days.filter { $0 < today || !hours.isOpen(at: Date()) }.sorted(by: >)
    }

    func replayStep(_ count: Int = 1) {
        guard var session = replay else { return }
        var events: [OrderEvent] = []
        for _ in 0..<count where !session.isFinished { events += session.step() }
        replay = session
        for case .filled(let order) in events {
            showToast("Replay: \(order.side.rawValue) \(Format.shares(order.shares)) filled at \(Format.money(order.fillPrice ?? 0))")
        }
    }

    @discardableResult
    func replaySubmit(_ request: OrderRequest) -> Bool {
        guard var session = replay else { return false }
        switch session.submit(request) {
        case .success(let order):
            replay = session
            if order.status == .filled { showToast("Replay: filled at \(Format.money(order.fillPrice ?? 0))") }
            return true
        case .failure(let rejection):
            notice = rejection.message
            return false
        }
    }

    func replayCancel(_ id: UUID) {
        guard var session = replay else { return }
        session.cancel(id)
        replay = session
    }

    func finishReplay() {
        guard var session = replay else { return }
        let record = session.finish()
        workspace.features.barReplays.insert(record, at: 0)
        replay = nil
        recordAction("replay")
        notice = "Replay of \(record.symbol) on \(record.day.formatted(date: .abbreviated, time: .omitted)): \(record.trades) \(record.trades == 1 ? "trade" : "trades"), \(Format.signedMoney(record.netPnL)) net."
    }
}
