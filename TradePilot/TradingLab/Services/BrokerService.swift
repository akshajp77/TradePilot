import Foundation

/// A real Alpaca account (paper or live), connected with the user's own API keys or with OAuth.
/// Credentials live in the Keychain on this device only and never sync.
@MainActor
final class BrokerService: ObservableObject {
    @Published private(set) var environment: BrokerEnvironment?
    @Published private(set) var usesOAuth = false
    @Published private(set) var account: LiveAccount?
    @Published private(set) var positions: [LivePosition] = []
    @Published private(set) var openOrders: [LiveOrder] = []
    @Published private(set) var recentOrders: [LiveOrder] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var busy = false

    private var auth: BrokerAuth?
    private var pollTask: Task<Void, Never>?
    private var pollers = 0

    var isConnected: Bool { auth != nil && environment != nil }
    var isLive: Bool { environment == .live }

    init() {
        guard let envRaw = Keychain.read(.brokerEnvironment), let env = BrokerEnvironment(rawValue: envRaw) else { return }
        if let token = Keychain.read(.brokerToken) {
            auth = .oauth(token: token); usesOAuth = true
        } else if let id = Keychain.read(.brokerKeyID), let secret = Keychain.read(.brokerSecret) {
            auth = .keys(id: id, secret: secret)
        }
        if auth != nil { environment = env }
    }

    // MARK: Connecting

    /// Connects with API keys and checks them against /v2/account. Returns an error message, or nil on success.
    func connect(keyID: String, secret: String, environment env: BrokerEnvironment) async -> String? {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines), sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !sec.isEmpty else { return "Enter both the key ID and the secret key." }
        return await adopt(.keys(id: id, secret: sec), env: env) {
            Keychain.save(id, for: .brokerKeyID); Keychain.save(sec, for: .brokerSecret); Keychain.save("", for: .brokerToken)
        }
    }

    /// The Alpaca consent page URL for OAuth. `state` must be checked when the callback arrives.
    static func authorizeURL(clientID: String, redirectURI: String, environment env: BrokerEnvironment, state: String) -> URL? {
        var parts = URLComponents(string: "https://app.alpaca.markets/oauth/authorize")
        parts?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "account:write trading"),
            URLQueryItem(name: "env", value: env.rawValue),
        ]
        return parts?.url
    }

    /// Finishes OAuth: checks state, trades the code for a token on the Trading Lab server, verifies it.
    func completeOAuth(callback: URL, expectedState: String, redirectURI: String, environment env: BrokerEnvironment,
                       accountService: AccountService) async -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { return "Alpaca sign-in was canceled (\(error))." }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return "The sign-in response didn't match. Try again." }
        guard let code = items.first(where: { $0.name == "code" })?.value else { return "Alpaca didn't return a sign-in code." }
        do {
            let (data, status) = try await accountService.send("POST", "brokers/alpaca/token", json: ["code": code, "redirectUri": redirectURI])
            guard status == 200, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let token = o["accessToken"] as? String else { return AccountService.errorMessage(data, status: status) }
            return await adopt(.oauth(token: token), env: env) {
                Keychain.save(token, for: .brokerToken); Keychain.save("", for: .brokerKeyID); Keychain.save("", for: .brokerSecret)
            }
        } catch {
            return "Sign in to Trading Lab first (Settings → Account & sync), then connect Alpaca."
        }
    }

    private func adopt(_ candidate: BrokerAuth, env: BrokerEnvironment, save: () -> Void) async -> String? {
        busy = true
        defer { busy = false }
        let (data, status) = await request("GET", "/v2/account", auth: candidate, env: env)
        guard status == 200, let parsed = AlpacaTrading.account(data) else {
            return status == 0 ? "Couldn't reach Alpaca. Check your connection." : AlpacaTrading.errorMessage(status: status, data: data)
        }
        save()
        Keychain.save(env.rawValue, for: .brokerEnvironment)
        auth = candidate
        usesOAuth = { if case .oauth = candidate { return true } else { return false } }()
        environment = env
        account = parsed
        lastError = nil
        await refresh()
        return nil
    }

    func disconnect() {
        for item in [Keychain.Item.brokerKeyID, .brokerSecret, .brokerToken, .brokerEnvironment] { Keychain.save("", for: item) }
        auth = nil; environment = nil; account = nil
        positions = []; openOrders = []; recentOrders = []
        stopPolling(force: true)
    }

    // MARK: Reading

    func refresh() async {
        guard let auth, let env = environment else { return }
        async let accountReply = request("GET", "/v2/account", auth: auth, env: env)
        async let positionsReply = request("GET", "/v2/positions", auth: auth, env: env)
        async let openReply = request("GET", "/v2/orders?status=open&nested=true&limit=200", auth: auth, env: env)
        async let closedReply = request("GET", "/v2/orders?status=closed&nested=true&limit=50&direction=desc", auth: auth, env: env)
        let (a, p, o, c) = await (accountReply, positionsReply, openReply, closedReply)
        if a.1 == 401 { lastError = AlpacaTrading.errorMessage(status: 401, data: a.0); return }
        if a.1 == 200, let parsed = AlpacaTrading.account(a.0) { account = parsed }
        if p.1 == 200 { positions = AlpacaTrading.positions(p.0).sorted { $0.symbol < $1.symbol } }
        if o.1 == 200 { openOrders = AlpacaTrading.orders(o.0) }
        if c.1 == 200 { recentOrders = AlpacaTrading.orders(c.0) }
        if [a.1, p.1, o.1].allSatisfy({ $0 == 200 }) { lastError = nil; lastUpdated = Date() }
        else if a.1 == 0 { lastError = "Couldn't reach Alpaca. Showing the last update." }
    }

    /// Screens that show live data call start/stop; polling runs while any of them is visible.
    func startPolling() {
        pollers += 1
        guard pollTask == nil, isConnected else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopPolling(force: Bool = false) {
        pollers = force ? 0 : max(0, pollers - 1)
        if pollers == 0 { pollTask?.cancel(); pollTask = nil }
    }

    func position(_ symbol: String) -> LivePosition? { positions.first { $0.symbol == symbol } }
    func orders(_ symbol: String) -> [LiveOrder] {
        openOrders.flatMap { [$0] + $0.legs }.filter { $0.symbol == symbol && $0.isOpen }
    }

    // MARK: Trading

    /// Sends a real order. Returns the accepted order or a beginner-friendly error.
    func place(_ r: OrderRequest) async -> Result<LiveOrder, BrokerFailure> {
        if let problem = AlpacaTrading.validate(r) { return .failure(BrokerFailure(message: problem)) }
        guard let auth, let env = environment else { return .failure(BrokerFailure(message: "Connect an Alpaca account first.")) }
        if account?.tradingBlocked == true { return .failure(BrokerFailure(message: "Alpaca has blocked trading on this account. Check your Alpaca dashboard.")) }
        guard let body = try? JSONSerialization.data(withJSONObject: AlpacaTrading.orderBody(r)) else { return .failure(BrokerFailure(message: "The order couldn't be prepared.")) }
        busy = true
        defer { busy = false }
        let (data, status) = await request("POST", "/v2/orders", body: body, auth: auth, env: env)
        guard status == 200, let order = AlpacaTrading.singleOrder(data) else {
            return .failure(BrokerFailure(message: status == 0 ? "Couldn't reach Alpaca. The order may not have been sent; check your orders before trying again." : AlpacaTrading.errorMessage(status: status, data: data)))
        }
        await refresh()
        return .success(order)
    }

    func cancel(_ id: String) async -> String? {
        guard let auth, let env = environment else { return "Not connected." }
        let (data, status) = await request("DELETE", "/v2/orders/\(id)", auth: auth, env: env)
        await refresh()
        return (200...204).contains(status) ? nil : AlpacaTrading.errorMessage(status: status, data: data)
    }

    func cancelAll() async -> String? {
        guard let auth, let env = environment else { return "Not connected." }
        let (data, status) = await request("DELETE", "/v2/orders", auth: auth, env: env)
        await refresh()
        return (200...207).contains(status) ? nil : AlpacaTrading.errorMessage(status: status, data: data)
    }

    /// Moves a working order's price (PATCH replaces it with a new order ID).
    func replace(_ order: LiveOrder, price: Decimal) async -> String? {
        guard let auth, let env = environment else { return "Not connected." }
        var fields: [String: Any] = [:]
        let value = NSDecimalNumber(decimal: price.tickRounded).stringValue
        if order.type == "stop" { fields["stop_price"] = value } else { fields["limit_price"] = value }
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { return "Couldn't prepare the change." }
        let (data, status) = await request("PATCH", "/v2/orders/\(order.id)", body: body, auth: auth, env: env)
        await refresh()
        return status == 200 ? nil : AlpacaTrading.errorMessage(status: status, data: data)
    }

    /// Closes a whole position at market (Alpaca cancels conflicting orders first when asked).
    func close(_ symbol: String) async -> String? {
        guard let auth, let env = environment else { return "Not connected." }
        let (data, status) = await request("DELETE", "/v2/positions/\(symbol)", auth: auth, env: env)
        await refresh()
        return (200...207).contains(status) ? nil : AlpacaTrading.errorMessage(status: status, data: data)
    }

    func closeAll() async -> String? {
        guard let auth, let env = environment else { return "Not connected." }
        let (data, status) = await request("DELETE", "/v2/positions?cancel_orders=true", auth: auth, env: env)
        await refresh()
        return (200...207).contains(status) ? nil : AlpacaTrading.errorMessage(status: status, data: data)
    }

    // MARK: HTTP

    private nonisolated func request(_ method: String, _ path: String, body: Data? = nil, auth: BrokerAuth, env: BrokerEnvironment) async -> (Data, Int) {
        guard let url = URL(string: env.baseURL.absoluteString + path) else { return (Data(), 0) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        for (k, v) in auth.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (Data(), 0) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct BrokerFailure: Error { let message: String }
