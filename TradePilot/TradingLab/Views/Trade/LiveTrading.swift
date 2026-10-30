import SwiftUI
import AuthenticationServices

// MARK: - Settings → Real-money trading

/// Readiness checklist, then connecting an Alpaca account with OAuth or API keys.
struct LiveTradingSetupView: View {
    @Environment(\.theme) private var theme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @ObservedObject var store: LabStore
    @ObservedObject var broker: BrokerService
    @ObservedObject var account: AccountService
    @State private var environment: BrokerEnvironment = .paper
    @State private var keyID = ""
    @State private var secret = ""
    @State private var working = false
    @State private var oauth: (clientID: String, redirectURI: String)?
    @State private var overrideText = ""
    @State private var showOverride = false
    @State private var ageText = ""
    @State private var confirmDisconnect = false

    private static let overridePhrase = "I understand I can lose real money"

    var body: some View {
        let items = store.readinessItems
        let ready = Readiness.isReady(items)
        Form {
            Section {
                Text("Practice here first. When you're ready, connect an Alpaca brokerage account to trade real stocks from this app. Alpaca is a US broker regulated by FINRA and the SEC; Trading Lab never holds your money.")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
            if store.profile?.birthYear == nil {
                Section("Your age") {
                    TextField("Age", text: $ageText).appNumberKeyboard(.whole)
                    Button("Save") { if let age = Int(ageText), (10...110).contains(age) { store.updateAge(age) } }
                        .disabled(Int(ageText) == nil)
                }
            }
            Section {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: Space.s12) {
                        Image(systemName: item.met ? "checkmark.circle.fill" : "circle").foregroundStyle(item.met ? theme.accent : theme.muted).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(theme.label)
                            Text(item.detail).font(theme.meta).foregroundStyle(theme.muted)
                            if !item.met { ProgressView(value: item.progress).tint(theme.accent) }
                        }
                    }
                }
            } header: {
                Text("Before real money")
            } footer: {
                Text(ready ? "You've earned it. Start small: an amount you could lose without it affecting your life."
                     : "These come from what tends to separate luck from skill. Alpaca's paper (fake money) account works any time.")
            }
            if !ready && Readiness.canOverride(items) && store.learning.liveOverrideAt == nil {
                Section {
                    if showOverride {
                        Text("Type \"\(Self.overridePhrase)\" to unlock real-money trading before finishing the checklist.").font(theme.meta)
                        TextField(Self.overridePhrase, text: $overrideText).autocorrectionDisabled()
                        Button("Unlock real-money trading", role: .destructive) { store.acceptLiveOverride() }
                            .disabled(overrideText.trimmingCharacters(in: .whitespaces).lowercased() != Self.overridePhrase.lowercased())
                    } else {
                        Button("Skip the checklist…") { showOverride = true }.foregroundStyle(theme.muted)
                    }
                } footer: { Text("Most people who skip practice lose money faster. The coach will keep flagging risky trades either way.") }
            }

            if broker.isConnected {
                connectedSection
            } else {
                connectSection(ready: ready)
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Real-money trading")
        .task { oauth = await Feeds.alpacaOAuthConfig() }
        .confirmationDialog("Disconnect Alpaca?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { broker.disconnect() }
        } message: { Text("Your Alpaca account and its positions aren't affected. Open orders keep working at Alpaca.") }
    }

    private var connectedSection: some View {
        Section("Connected") {
            ExplainRow("Account", value: broker.environment?.title ?? "")
            if let a = broker.account {
                LabeledContent("Account value", value: Format.money(a.equity)).holdToExplain("Account value", value: Format.money(a.equity), context: ["Your real Alpaca account."], practice: false)
                LabeledContent("Buying power", value: Format.money(a.buyingPower)).holdToExplain("Buying power", value: Format.money(a.buyingPower), context: ["Your real Alpaca account."], practice: false)
                if a.tradingBlocked { Text("Alpaca has blocked trading on this account.").foregroundStyle(theme.loss) }
            }
            ExplainRow("Connected with", value: broker.usesOAuth ? "Alpaca sign-in" : "API keys")
            NavigationLink("Open your Alpaca account") { LiveAccountView(store: store, broker: broker) }
            Button("Disconnect", role: .destructive) { confirmDisconnect = true }
        }
    }

    @ViewBuilder private func connectSection(ready: Bool) -> some View {
        Section {
            Picker("Account", selection: $environment) {
                Text("Paper (fake money)").tag(BrokerEnvironment.paper)
                Text("Live (real money)").tag(BrokerEnvironment.live)
            }
            .pickerStyle(.segmented)
            if environment == .live && !store.liveTradingAllowed(.live) {
                Text(store.profile?.isAdult() == false ? "Real-money trading is for adults (18+)." : "Finish the checklist above (or skip it) to connect a live account.")
                    .font(theme.meta).foregroundStyle(theme.loss)
            }
        } header: { Text("Connect Alpaca") }

        let allowed = store.liveTradingAllowed(environment)
        if let oauth {
            Section {
                Button {
                    Task { await connectOAuth(oauth) }
                } label: {
                    HStack { Label("Sign in with Alpaca", systemImage: "person.badge.key"); if working { Spacer(); ProgressView() } }
                }
                .disabled(!allowed || working || !account.signedIn)
            } footer: {
                Text(account.signedIn ? "You'll sign in on Alpaca's own website. Trading Lab gets permission to place trades; it never sees your Alpaca password."
                     : "Sign in to Trading Lab first (Settings → Account & sync) to connect with Alpaca sign-in, or use API keys below.")
            }
        }
        Section {
            SecureField("API key ID", text: $keyID).appCapitalization(.never).autocorrectionDisabled()
            SecureField("Secret key", text: $secret).appCapitalization(.never).autocorrectionDisabled()
            Button {
                Task {
                    working = true
                    if let error = await broker.connect(keyID: keyID, secret: secret, environment: environment) { store.notice = error }
                    else { keyID = ""; secret = ""; store.showToast("Alpaca connected") }
                    working = false
                }
            } label: { HStack { Text("Connect with API keys"); if working { Spacer(); ProgressView() } } }
            .disabled(!allowed || working || keyID.isEmpty || secret.isEmpty)
        } header: {
            Text("Or use API keys")
        } footer: {
            Text("In your Alpaca dashboard, open \(environment == .paper ? "your paper account" : "your live account") and generate API keys. Keys are stored only in this device's Keychain. Paper and live accounts have different keys.")
        }
    }

    private func connectOAuth(_ config: (clientID: String, redirectURI: String)) async {
        let state = UUID().uuidString
        guard let url = BrokerService.authorizeURL(clientID: config.clientID, redirectURI: config.redirectURI, environment: environment, state: state),
              let scheme = URL(string: config.redirectURI)?.scheme else { return }
        working = true
        defer { working = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            if let error = await broker.completeOAuth(callback: callback, expectedState: state, redirectURI: config.redirectURI,
                                                      environment: environment, accountService: account) {
                store.notice = error
            } else {
                store.showToast("Alpaca connected")
            }
        } catch {
            // Canceled by the user.
        }
    }
}

// MARK: - The connected account

struct LiveAccountView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var broker: BrokerService
    @State private var confirmCloseAll = false

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                HStack {
                    Label(broker.isLive ? "Real money" : "Alpaca paper", systemImage: broker.isLive ? "exclamationmark.octagon.fill" : "testtube.2")
                        .font(theme.label).foregroundStyle(broker.isLive ? theme.loss : theme.warning)
                    Spacer()
                    if let updated = broker.lastUpdated { Text("Updated \(updated.formatted(date: .omitted, time: .standard))").font(theme.meta).foregroundStyle(theme.muted) }
                }
                if let error = broker.lastError { Text(error).font(theme.meta).foregroundStyle(theme.loss) }
                if let a = broker.account {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Account value")
                        Text(Format.money(a.equity)).font(theme.display).monospacedDigit()
                            .holdToExplain("Account value", value: Format.money(a.equity), context: ["Your real Alpaca account."], practice: false)
                        Text("\(Format.signedMoney(a.dayChange)) today").font(theme.label).foregroundStyle(theme.gain(a.dayChange >= 0))
                            .holdToExplain("Today", value: Format.signedMoney(a.dayChange), term: "P&L", context: ["Your real Alpaca account."], tone: theme.gain(a.dayChange >= 0), practice: false)
                    }
                    HStack(spacing: Space.s24) {
                        VStack(alignment: .leading) { Text("Cash").font(theme.meta).foregroundStyle(theme.muted); Text(Format.money(a.cash)).font(theme.label.monospacedDigit()).holdToExplain("Cash", value: Format.money(a.cash), context: ["Your real Alpaca account."], practice: false) }
                        VStack(alignment: .leading) {
                            HStack(spacing: 2) { Text("Buying power").font(theme.meta).foregroundStyle(theme.muted); ExplainButton(term: "Buying power", size: 11) }
                            Text(Format.money(a.buyingPower)).font(theme.label.monospacedDigit())
                                .holdToExplain("Buying power", value: Format.money(a.buyingPower), context: ["Your real Alpaca account."], practice: false)
                        }
                        VStack(alignment: .leading) { Text("Day trades (5 days)").font(theme.meta).foregroundStyle(theme.muted); Text("\(a.dayTradeCount)").font(theme.label.monospacedDigit()).holdToExplain("Day trades (5 days)", value: "\(a.dayTradeCount)", term: "Day trade", context: ["Your real Alpaca account."], practice: false) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                HStack {
                    Text("Positions").font(theme.section)
                    Spacer()
                    if !broker.positions.isEmpty { Button("Close all", role: .destructive) { confirmCloseAll = true }.font(theme.meta).foregroundStyle(theme.loss) }
                }
                LivePositionsList(store: store, broker: broker) { store.openChart($0) }
                Text("Open orders").font(theme.section)
                LiveOrdersList(store: store, broker: broker)
                Text("Recent fills").font(theme.section)
                LiveFillsList(broker: broker)
                Text("Orders, fills and buying power come from Alpaca. Your practice account and journal stay separate.").font(theme.meta).foregroundStyle(theme.muted)
            }
        }
        .navigationTitle("Alpaca").appInlineTitle()
        .onAppear { broker.startPolling() }
        .onDisappear { broker.stopPolling() }
        .refreshable { await broker.refresh() }
        .confirmationDialog("Close every position at market?", isPresented: $confirmCloseAll, titleVisibility: .visible) {
            Button("Close all and cancel orders", role: .destructive) { Task { if let e = await broker.closeAll() { store.notice = e } } }
        } message: { Text(broker.isLive ? "This sells real positions at the current market price." : "This closes your paper positions.") }
    }
}

struct LivePositionsList: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var broker: BrokerService
    var onSelect: (String) -> Void = { _ in }
    @State private var closing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if broker.positions.isEmpty { Text("No positions at Alpaca.").font(theme.label).foregroundStyle(theme.muted).padding(.vertical, Space.s12) }
            ForEach(broker.positions) { p in
                HStack {
                    Button { onSelect(p.symbol) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(p.symbol) · \(p.quantity > 0 ? "long" : "short") \(Format.shares(abs(p.quantity)))").font(theme.label)
                            Text("Avg \(Format.money(p.averageEntry)) · now \(Format.money(p.currentPrice))").font(theme.meta).foregroundStyle(theme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text(Format.signedMoney(p.unrealized)).font(theme.label.monospacedDigit()).foregroundStyle(theme.gain(p.unrealized >= 0))
                        .holdToExplain("Unrealized", value: Format.signedMoney(p.unrealized), context: ["\(p.symbol) in your real Alpaca account."], tone: theme.gain(p.unrealized >= 0), practice: false)
                    Button("Close") { closing = p.symbol }.font(theme.meta).buttonStyle(.borderless).foregroundStyle(theme.loss)
                }
                .padding(.vertical, Space.s8)
                Rule()
            }
        }
        .confirmationDialog("Close \(closing ?? "")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("Close at market", role: .destructive) {
                if let symbol = closing { Task { if let e = await broker.close(symbol) { store.notice = e } } }
                closing = nil
            }
        } message: { Text(broker.isLive ? "Real money: this sells (or buys back) the whole position at the current price." : "Paper account.") }
    }
}

struct LiveOrdersList: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var broker: BrokerService
    var body: some View {
        let orders = broker.openOrders.flatMap { [$0] + $0.legs.filter(\.isOpen) }
        VStack(alignment: .leading, spacing: 0) {
            if orders.isEmpty { Text("No open orders.").font(theme.label).foregroundStyle(theme.muted).padding(.vertical, Space.s12) }
            ForEach(orders) { order in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(order.summary).font(theme.label).foregroundStyle(order.side == .buy ? theme.stockGain : theme.stockLoss)
                        Text(order.statusText).font(theme.meta).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    Button { Task { if let e = await broker.cancel(order.id) { store.notice = e } } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(theme.muted)
                    }.buttonStyle(.plain).accessibilityLabel("Cancel \(order.summary)")
                }
                .padding(.vertical, Space.s8)
                Rule()
            }
        }
    }
}

struct LiveFillsList: View {
    @Environment(\.theme) private var theme
    @ObservedObject var broker: BrokerService
    var body: some View {
        let fills = broker.recentOrders.filter { $0.filledAt != nil }.prefix(20)
        VStack(alignment: .leading, spacing: 0) {
            if fills.isEmpty { Text("No recent fills.").font(theme.label).foregroundStyle(theme.muted).padding(.vertical, Space.s12) }
            ForEach(Array(fills)) { order in
                HStack {
                    Text(order.filledAt?.formatted(date: .abbreviated, time: .shortened) ?? "").font(theme.meta).foregroundStyle(theme.muted)
                    Text("\(order.side.rawValue) \(Format.shares(order.filledQuantity)) \(order.symbol)").font(theme.label)
                        .foregroundStyle(order.side == .buy ? theme.stockGain : theme.stockLoss)
                    Spacer()
                    Text(order.filledAverage.map(Format.money) ?? "—").font(theme.label.monospacedDigit())
                }
                .padding(.vertical, 6)
                Rule()
            }
        }
    }
}
