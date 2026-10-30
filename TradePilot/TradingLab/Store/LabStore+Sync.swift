import Foundation
import WidgetKit

/// Saving to disk, the home-screen widget and account sync.
extension LabStore {
    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.workspace
            guard let data = await offMain({ try? WorkspaceCodec.encode(snapshot) }) else { return }
            self.file.write(data)
        }
    }

    func flushToDisk() {
        saveTask?.cancel()
        if let data = try? WorkspaceCodec.encode(workspace) { try? file.writeNow(data) }
    }

    // MARK: Widget

    func publishWidget() {
        guard liveServices else { return }
        WidgetBridge.write(value: pricesReady ? portfolioValue?.double : nil, cash: cash.double, name: activeTitle,
                           symbols: data.watched, lesson: nextLearningTitle)
    }

    // MARK: Sync

    func accountChanged(_ signedIn: Bool) {
        revision = nil
        if signedIn {
            syncStatus = "Signed in"
            Task { await account.loadProfile(); await syncNow() }
        } else {
            syncStatus = "Not signed in"
        }
    }

    func scheduleSync() {
        guard account.signedIn else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private struct SyncEnvelope: Decodable {
        let revision: Int
        let snapshot: Workspace?
    }

    func syncNow() async {
        guard account.signedIn else { syncStatus = "Not signed in"; return }
        if isSyncing { syncAgain = true; return }
        isSyncing = true
        defer { isSyncing = false }
        var rounds = 0
        repeat {
            syncAgain = false
            rounds += 1
            do {
                if revision == nil {
                    syncStatus = "Checking for a synced copy…"
                    let (data, status) = try await account.send("GET", "sync")
                    guard status == 200 else { throw AccountError.server(status: status, code: "", message: AccountService.errorMessage(data, status: status)) }
                    let envelope = try JSONDecoder().decode(SyncEnvelope.self, from: data)
                    if let remote = envelope.snapshot { applyRemote(remote) }
                    revision = envelope.revision
                }
                try await push()
            } catch let error as AccountError {
                syncStatus = error == .network ? "Offline · changes are saved on this device" : error.message
                return
            } catch {
                syncStatus = "Sync failed · the synced copy could not be read"
                return
            }
        } while (syncAgain || localChange != syncedChange) && rounds < 3
    }

    private func push() async throws {
        for _ in 0..<3 {
            syncStatus = "Saving…"
            let startedAt = localChange
            let snapshot = workspace
            guard let encoded = await offMain({ try? WorkspaceCodec.encode(snapshot) }),
                  let object = try? JSONSerialization.jsonObject(with: encoded) else { throw AccountError.network }
            var body: [String: Any] = ["baseRevision": revision ?? 0, "snapshot": object]
            if let stats = publicStats() { body["stats"] = stats }
            let (data, status) = try await account.send("PUT", "sync", json: body)
            switch status {
            case 200:
                struct Saved: Decodable { let revision: Int }
                revision = try JSONDecoder().decode(Saved.self, from: data).revision
                syncedChange = startedAt
                syncStatus = "Up to date · \(Date().formatted(date: .omitted, time: .shortened))"
                return
            case 409:
                let envelope = try JSONDecoder().decode(SyncEnvelope.self, from: data)
                if let remote = envelope.snapshot { applyRemote(remote) }
                revision = envelope.revision
            default:
                throw AccountError.server(status: status, code: "", message: AccountService.errorMessage(data, status: status))
            }
        }
        syncStatus = "Another device keeps changing this account. Try again in a moment."
    }

    private func applyRemote(_ remote: Workspace) {
        let merged = WorkspaceMerge.merge(local: workspace, remote: remote)
        guard merged != workspace else { return }
        workspace = merged
    }

    private func publicStats() -> [String: Any]? {
        guard let primary = workspace.portfolios.first(where: { $0.id == Portfolio.primaryID }) else { return nil }
        let ledger = Ledger(primary.account)
        guard primary.account.initialBalance > 0, let value = ledger.value(price: { self.market.decimalPrice($0) }) else { return nil }
        let returnPct = (value / primary.account.initialBalance - 1).double
        guard returnPct.isFinite else { return nil }
        return ["returnPct": max(-1, min(100, returnPct)), "asOf": ISO8601DateFormatter().string(from: Date())]
    }

    func setPublicRecord(alias: String?, isPublic: Bool) async -> String? {
        let message = await account.updateProfile(alias: alias, isPublic: isPublic)
        if message == nil { localChange += 1; await syncNow() }
        return message
    }
}

// MARK: - Widget bridge

@MainActor
enum WidgetBridge {
    // Enable this App Group on the app and widget targets to share the snapshot.
    static let group = "group.com.tradinglab.shared"
    private static var lastWrite = Date.distantPast

    static func write(value: Double?, cash: Double, name: String, symbols: [String], lesson: String) {
        guard Date().timeIntervalSince(lastWrite) > 30, let defaults = UserDefaults(suiteName: group) else { return }
        lastWrite = Date()
        defaults.set(value, forKey: "value"); defaults.set(cash, forKey: "cash")
        defaults.set(name, forKey: "name"); defaults.set(symbols, forKey: "symbols")
        defaults.set(lesson, forKey: "lesson"); defaults.set(Date(), forKey: "updated")
        WidgetCenter.shared.reloadTimelines(ofKind: "TradingLabSnapshot")
    }
}
