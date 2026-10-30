import Foundation

nonisolated enum WorkspaceCodec {
    static func encode(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(workspace)
    }
    static func decode(_ data: Data) throws -> Workspace {
        var workspace = try JSONDecoder().decode(Workspace.self, from: data)
        if workspace.portfolios.isEmpty { workspace.portfolios = Workspace.fresh().portfolios }
        if !workspace.portfolios.contains(where: { $0.id == workspace.activePortfolioID }) {
            workspace.activePortfolioID = workspace.portfolios[0].id
        }
        workspace.schemaVersion = Workspace.currentVersion
        return workspace
    }
}

/// One JSON file in Application Support, written atomically off the main thread.
/// Replaces the v1/v2 habit of storing years of history and every order in UserDefaults.
nonisolated final class WorkspaceFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "trading-lab.workspace-file", qos: .utility)

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("TradingLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("workspace.json")
    }

    func load() -> Workspace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? WorkspaceCodec.decode(data)
    }

    func write(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        let url = self.url
        queue.async {
            do { try data.write(to: url, options: [.atomic]); completion?(nil) }
            catch { completion?(error) }
        }
    }

    func writeNow(_ data: Data) throws {
        try queue.sync { try data.write(to: url, options: [.atomic]) }
    }

    func delete() { queue.sync { try? FileManager.default.removeItem(at: url) } }
}

/// Reads the v1/v2 UserDefaults layout once and turns it into a Workspace.
nonisolated enum LegacyMigration {
    static let accountKey = "trading-lab-local-v1"
    static let historyKey = "trading-lab-portfolio-history-v2"
    static let customKey = "trading-lab-custom-securities-v1"
    static let featureKey = "trading-lab-features-v1"
    static let doneKey = "trading-lab-migrated-v3"

    private struct LegacyPortfolio: Decodable {
        var id: String
        var title: String
        var account: AccountData
        var history: [PortfolioSample]?
    }
    private struct LegacyFeatureShell: Decodable {
        var portfolios: [LegacyPortfolio]?
        var activePortfolio: String?
    }

    static func migrate(from defaults: UserDefaults) -> Workspace? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        let decoder = JSONDecoder()
        let account = defaults.data(forKey: accountKey).flatMap { try? decoder.decode(AccountData.self, from: $0) }
        let history = defaults.data(forKey: historyKey).flatMap { try? decoder.decode([PortfolioSample].self, from: $0) } ?? []
        let featureData = defaults.data(forKey: featureKey)
        let shell = featureData.flatMap { try? decoder.decode(LegacyFeatureShell.self, from: $0) }
        let features = featureData.flatMap { try? decoder.decode(UserFeatures.self, from: $0) } ?? UserFeatures()
        guard account != nil || shell?.portfolios?.isEmpty == false else { return nil }

        let active = shell?.activePortfolio ?? Portfolio.primaryID
        var portfolios = (shell?.portfolios ?? []).map {
            Portfolio(id: $0.id, title: $0.title, account: $0.account, history: $0.history ?? [])
        }
        if let account {
            // The standalone blob is the freshest copy of whichever portfolio was active.
            if let i = portfolios.firstIndex(where: { $0.id == active }) {
                portfolios[i].account = account
                if !history.isEmpty { portfolios[i].history = history }
            } else {
                portfolios.insert(Portfolio(id: active, title: active == Portfolio.primaryID ? "Main portfolio" : "Portfolio",
                                            account: account, history: history), at: 0)
            }
        }
        var workspace = Workspace(portfolios: portfolios, activePortfolioID: active, features: features)
        workspace.customSecurities = defaults.data(forKey: customKey)
            .flatMap { try? decoder.decode([Security].self, from: $0) }?
            .filter { MarketCatalog.security($0.symbol) == nil } ?? []
        workspace.pruneOrphans()
        return workspace
    }

    static func markDone(_ defaults: UserDefaults) { defaults.set(true, forKey: doneKey) }
}
