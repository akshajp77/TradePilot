import Foundation

/// Three-way-free merge of two workspace copies. Orders are immutable apart from status and
/// reflection, so they union cleanly by ID; everything else merges by ID with tombstones for deletes.
nonisolated enum WorkspaceMerge {
    static func merge(local: Workspace, remote: Workspace) -> Workspace {
        var result = local
        result.tombstones = local.tombstones.merging(remote.tombstones) { max($0, $1) }
        let dead = result.tombstones

        func alive(_ kind: String, _ id: String, createdAt: Date? = nil) -> Bool {
            guard let deletedAt = dead["\(kind):\(id)"] else { return true }
            return (createdAt ?? .distantPast) > deletedAt
        }

        // Portfolios
        var portfolios: [Portfolio] = []
        for portfolio in local.portfolios where alive("portfolio", portfolio.id) {
            if let other = remote.portfolios.first(where: { $0.id == portfolio.id }) {
                portfolios.append(mergePortfolio(portfolio, other))
            } else {
                portfolios.append(portfolio)
            }
        }
        for portfolio in remote.portfolios where alive("portfolio", portfolio.id) && !portfolios.contains(where: { $0.id == portfolio.id }) {
            portfolios.append(portfolio)
        }
        if portfolios.isEmpty { portfolios = Workspace.fresh(name: local.portfolios.first?.account.name ?? "").portfolios }
        result.portfolios = portfolios
        if !portfolios.contains(where: { $0.id == result.activePortfolioID }) { result.activePortfolioID = portfolios[0].id }

        result.customSecurities = unionBy(local.customSecurities, remote.customSecurities, key: \.symbol)
            .filter { alive("security", $0.symbol, createdAt: $0.addedAt) }

        // Features
        var f = local.features
        let r = remote.features
        f.watchlists = unionBy(f.watchlists, r.watchlists, key: \.id).filter { alive("watchlist", $0.id) }
        f.tradeNotes = r.tradeNotes.merging(f.tradeNotes) { _, mine in mine }
        f.research = unionBy(f.research, r.research, key: \.id) { $0.savedAt >= $1.savedAt ? $0 : $1 }
            .filter { alive("research", $0.id, createdAt: $0.savedAt) }
        // A schedule that ran on either device must not run again: keep the later next date.
        f.recurring = unionBy(f.recurring, r.recurring, key: \.id) { $0.nextDate >= $1.nextDate ? $0 : $1 }
            .filter { alive("recurring", $0.id) }
        f.events = unionBy(f.events, r.events, key: \.id).filter { alive("event", $0.id) }
        f.alerts = unionBy(f.alerts, r.alerts, key: \.id) { $0.triggeredAt != nil ? $0 : $1 }
            .filter { alive("alert", $0.id) }
        f.replays = unionBy(f.replays, r.replays, key: \.id)
        f.drawings = unionBy(f.drawings, r.drawings, key: \.id).filter { alive("drawing", $0.id) }
        f.barReplays = unionBy(f.barReplays, r.barReplays, key: \.id).sorted { $0.completedAt > $1.completedAt }
        // Chart layout is a device preference: the local copy wins.
        f.completedBites = orderedUnion(f.completedBites, r.completedBites)
        f.guidedSteps = orderedUnion(f.guidedSteps, r.guidedSteps)
        f.learning = LearningState.merge(f.learning, r.learning)
        result.features = f
        result.pruneOrphans()
        return result
    }

    static func mergePortfolio(_ mine: Portfolio, _ theirs: Portfolio) -> Portfolio {
        var merged = mine
        merged.account = mergeAccount(mine.account, theirs.account)
        // History restarts with a reset; otherwise union by timestamp.
        if mine.account.resetAt == theirs.account.resetAt {
            var byDate: [Date: PortfolioSample] = [:]
            for sample in theirs.history + mine.history { byDate[sample.date] = sample }
            merged.history = byDate.values.sorted { $0.date < $1.date }
        } else if theirs.account.resetAt > mine.account.resetAt {
            merged.history = theirs.history
        }
        return merged
    }

    static func mergeAccount(_ mine: AccountData, _ theirs: AccountData) -> AccountData {
        // Across a reset, the newer epoch wins outright; unioning would resurrect wiped orders.
        if mine.resetAt != theirs.resetAt { return mine.resetAt > theirs.resetAt ? mine : theirs }
        var merged = mine.updatedAt >= theirs.updatedAt ? mine : theirs
        merged.updatedAt = max(mine.updatedAt, theirs.updatedAt)
        merged.onboardingComplete = mine.onboardingComplete || theirs.onboardingComplete
        // `watched` comes from the newer copy (toggling a watch bumps updatedAt), so removals stick.
        merged.completedLessons = orderedUnion(mine.completedLessons, theirs.completedLessons)
        merged.completedChecks = orderedUnion(mine.completedChecks, theirs.completedChecks)
        merged.orders = unionBy(mine.orders, theirs.orders, key: \.id, prefer: preferOrder)
            .sorted { $0.submittedAt > $1.submittedAt }
        return merged
    }

    /// Final states beat pending ones; otherwise the most recently updated copy wins.
    static func preferOrder(_ a: PracticeOrder, _ b: PracticeOrder) -> PracticeOrder {
        if a.status.isFinal != b.status.isFinal { return a.status.isFinal ? a : b }
        return a.updatedAt >= b.updatedAt ? a : b
    }

    static func unionBy<T, K: Hashable>(_ mine: [T], _ theirs: [T], key: KeyPath<T, K>,
                                        prefer: (T, T) -> T = { a, _ in a }) -> [T] {
        var result = mine
        var position: [K: Int] = [:]
        for (i, item) in mine.enumerated() { position[item[keyPath: key]] = i }
        for item in theirs {
            if let i = position[item[keyPath: key]] { result[i] = prefer(result[i], item) }
            else { position[item[keyPath: key]] = result.count; result.append(item) }
        }
        return result
    }

    static func orderedUnion(_ mine: [String], _ theirs: [String]) -> [String] {
        var seen = Set<String>()
        return (mine + theirs).filter { seen.insert($0).inserted }
    }
}
