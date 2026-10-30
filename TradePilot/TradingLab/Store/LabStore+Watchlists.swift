import Foundation

/// Securities, watchlists, chart preferences and drawings.
extension LabStore {
    // MARK: Securities and watchlists

    func toggleWatch(_ symbol: String) {
        mutateActive { account in
            if account.watched.contains(symbol) { account.watched.removeAll { $0 == symbol } } else { account.watched.append(symbol) }
        }
    }

    /// Adds a ticker if needed. Returns the security or nil after showing why.
    @discardableResult
    func ensureSecurity(_ input: String) async -> Security? {
        let symbol = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let existing = security(symbol) { return existing }
        guard var item = await Feeds.lookupSecurity(symbol) else {
            notice = "Symbol not found. Enter a US stock, ETF, or market index ticker."
            return nil
        }
        item.addedAt = Date()
        var updated = workspace
        updated.customSecurities.append(item)
        updated.tombstones["security:\(symbol)"] = nil
        workspace = updated
        return item
    }

    func addSecurity(_ input: String) async -> Bool {
        let symbol = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if security(symbol) != nil { notice = "\(symbol) is already in Markets."; return false }
        guard await ensureSecurity(symbol) != nil else { return false }
        if !data.watched.contains(symbol) { mutateActive { $0.watched.append(symbol) } }
        return true
    }

    func canRemoveSecurity(_ symbol: String) -> Bool {
        !workspace.portfolios.contains { portfolio in
            Ledger(portfolio.account).shares(symbol) != 0 || portfolio.account.orders.contains { $0.symbol == symbol && $0.status.isPending }
        }
    }

    func removeSecurity(_ symbol: String) {
        guard canRemoveSecurity(symbol) else {
            notice = "Close every position in \(symbol) and cancel its pending orders, in all portfolios, before removing it."
            return
        }
        var updated = workspace
        updated.customSecurities.removeAll { $0.symbol == symbol }
        for index in updated.portfolios.indices where updated.portfolios[index].account.watched.contains(symbol) {
            updated.portfolios[index].account.watched.removeAll { $0 == symbol }
            updated.portfolios[index].account.updatedAt = Date()
        }
        updated.tombstones["security:\(symbol)"] = Date()
        updated.pruneOrphans()
        workspace = updated
        if chartSymbol == symbol { chartSymbol = data.watched.first ?? "SPY" }
    }

    func createWatchlist(_ title: String) { workspace.features.watchlists.append(NamedWatchlist(title: title)) }

    func deleteWatchlist(_ id: String) {
        var updated = workspace
        updated.features.watchlists.removeAll { $0.id == id }
        updated.tombstones["watchlist:\(id)"] = Date()
        workspace = updated
    }

    func setWatchlist(_ id: String, symbol: String, included: Bool) {
        guard let i = workspace.features.watchlists.firstIndex(where: { $0.id == id }) else { return }
        var list = workspace.features.watchlists[i]
        if included { if !list.symbols.contains(symbol) { list.symbols.append(symbol) } }
        else { list.symbols.removeAll { $0 == symbol }; list.pinned.removeAll { $0 == symbol } }
        workspace.features.watchlists[i] = list
    }

    func togglePin(_ id: String, symbol: String) {
        guard let i = workspace.features.watchlists.firstIndex(where: { $0.id == id }) else { return }
        if workspace.features.watchlists[i].pinned.contains(symbol) { workspace.features.watchlists[i].pinned.removeAll { $0 == symbol } }
        else { workspace.features.watchlists[i].pinned.append(symbol) }
    }

    // MARK: Chart: preferences and drawings

    var chartPreferences: ChartPreferences {
        get { workspace.features.chart }
        set {
            let old = workspace.features.chart
            workspace.features.chart = newValue
            if newValue.indicators.count > old.indicators.count { recordAction("indicator") }
            if newValue.timeframe != old.timeframe { recordAction("chart") }
        }
    }

    func drawings(_ symbol: String) -> [ChartDrawing] { workspace.features.drawings.filter { $0.symbol == symbol } }

    func addDrawing(_ drawing: ChartDrawing) {
        workspace.features.drawings.append(drawing)
        recordAction("drawing")
    }

    func updateDrawing(_ drawing: ChartDrawing) {
        guard let i = workspace.features.drawings.firstIndex(where: { $0.id == drawing.id }) else { return }
        workspace.features.drawings[i] = drawing
    }

    func removeDrawing(_ id: String) {
        var updated = workspace
        updated.features.drawings.removeAll { $0.id == id }
        updated.tombstones["drawing:\(id)"] = Date()
        workspace = updated
    }

    func clearDrawings(_ symbol: String) {
        var updated = workspace
        for drawing in updated.features.drawings where drawing.symbol == symbol { updated.tombstones["drawing:\(drawing.id)"] = Date() }
        updated.features.drawings.removeAll { $0.symbol == symbol }
        workspace = updated
    }
}
