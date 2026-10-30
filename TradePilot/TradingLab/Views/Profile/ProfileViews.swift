import SwiftUI
import AuthenticationServices
#if os(macOS)
import AppKit
#endif

struct ProfileView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var news: NewsStore
    @ObservedObject var account: AccountService
    @State private var editedName = ""

    var body: some View {
        let orders = store.data.orders.filter { Calendar.current.isDateInToday($0.submittedAt) }
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Eyebrow(text: "Practice profile")
                    Text(store.data.name.isEmpty ? "Your profile" : store.data.name).font(theme.page).tracking(-0.6)
                }
                Rule()
                VStack(alignment: .leading, spacing: Space.s12) {
                    Text("Today’s recap").font(theme.section)
                    Text("\(orders.count) practice \(orders.count == 1 ? "order" : "orders") today · \(store.data.completedChecks.count) of \(Curriculum.lessons.count) learning checks complete.")
                    // Same feed and key as News → "All relevant".
                    let stories = news.todayCount(Array(Set(store.data.watched + store.heldSymbols)))
                    Text("\(stories) relevant news \(stories == 1 ? "story" : "stories") found today.").foregroundStyle(theme.muted)
                }
                Rule()
                AccountSummary(store: store, market: store.market)
                Rule()
                VStack(alignment: .leading, spacing: Space.s12) {
                    Text("Name").font(theme.section)
                    HStack {
                        TextField("Practice name", text: $editedName).appCapitalization(.words).inputField()
                        Button("Save") {
                            let cleaned = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty else { return }
                            store.mutateActive { $0.name = cleaned }
                            store.showToast("Name saved.")
                        }.disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Rule()
                NavigationLink { SettingsView(store: store, account: account) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.s4) {
                            Text("Data, sync & account settings").font(theme.label)
                            Text(account.signedIn ? store.syncStatus : "Sign in to sync").font(theme.meta).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(theme.meta)
                    }.foregroundStyle(theme.accent)
                }
                ProfileTools(store: store)
                Text("This is a practice account. Orders do not reach a brokerage.").font(theme.meta).foregroundStyle(theme.muted)
            }
        }
        .navigationTitle("Profile").appInlineTitle()
        .onAppear { editedName = store.data.name }
    }
}

private struct AccountSummary: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Account").font(theme.section)
            ExplainRow("Portfolio value", value: store.portfolioValue.map(Format.money) ?? "Pending prices")
            ExplainRow("Virtual cash", value: Format.money(store.cash))
            ExplainRow("Buying power", value: Format.money(store.availableBuyingPower))
            if let margin = store.margin {
                if margin.reserved > 0 { ExplainRow("Reserved for working orders", value: Format.money(margin.reserved)) }
                if store.settings.accountType == .margin {
                    ExplainRow("Maintenance requirement", value: Format.money(margin.maintenanceRequirement))
                    if margin.debitBalance > 0 { ExplainRow("Margin loan", value: Format.money(margin.debitBalance)) }
                }
            }
            ExplainRow("Account type", value: "\(store.settings.accountType.rawValue) · \(store.settings.regime.rawValue)")
            ExplainRow("Filled orders", value: "\(store.data.orders.filter { $0.status == .filled }.count)")
        }
    }
}

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var account: AccountService
    @State private var marketKey = ""
    @State private var marketSecret = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            AccountSection(store: store, account: account)
            UserPreferenceSections(store: store)
            Section("Trading") {
                NavigationLink { TradingSettingsView(store: store) } label: {
                    LabeledContent("Rules, fills & risk", value: "\(store.settings.accountType.rawValue) · \(store.settings.fillModel.rawValue) fills")
                }
                NavigationLink("Alerts") { AlertsView(store: store) }
                NavigationLink { LiveTradingSetupView(store: store, broker: store.broker, account: account) } label: {
                    LabeledContent("Real-money trading", value: store.broker.isConnected ? (store.broker.isLive ? "Live" : "Paper") : "Not connected")
                }
            }
            if !store.customSecurities.isEmpty {
                Section("Added markets") {
                    ForEach(store.customSecurities) { item in
                        HStack {
                            Text("\(item.symbol) · \(item.name)")
                            Spacer()
                            Button("Remove") { store.removeSecurity(item.symbol) }
                                .buttonStyle(.borderless).disabled(!store.canRemoveSecurity(item.symbol))
                        }
                    }
                }
            }
            Section("Market prices") {
                MarketStatusSettings(market: store.market)
                SecureField("Alpaca API key ID", text: $marketKey).appCapitalization(.never).autocorrectionDisabled()
                SecureField("Alpaca secret key", text: $marketSecret).appCapitalization(.never).autocorrectionDisabled()
                Button("Connect IEX") {
                    store.market.configure(key: marketKey, secret: marketSecret)
                    marketKey = ""; marketSecret = ""
                }
                .disabled(marketKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || marketSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if store.market.configured {
                    Button("Reconnect IEX") { store.market.connect() }
                    Button("Remove IEX keys", role: .destructive) { store.market.configure(key: "", secret: "") }
                }
            }
            Section("Practice account") {
                Button("Reset \(store.activeTitle)", role: .destructive) { confirmReset = true }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Settings")
        .confirmationDialog("Reset \(store.activeTitle)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset account and journal", role: .destructive) { store.reset() }
        } message: {
            Text("Positions, orders, lessons and reflections in this portfolio are removed, on every synced device. It returns to its \(Format.money(store.startingBalance)) starting balance.")
        }
    }
}

private struct MarketStatusSettings: View {
    @Environment(\.theme) private var theme
    @ObservedObject var market: MarketData
    var body: some View {
        Text(market.statusText).font(theme.label)
        Text("Delayed prices load automatically and refresh every minute while the market is open. Optional Alpaca keys add live IEX trades; IEX is one exchange, so a trade may not arrive immediately.")
            .font(theme.meta).foregroundStyle(theme.muted)
    }
}

/// Sign in with Apple, sync, the opt-in public record, devices and account deletion.
struct AccountSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: LabStore
    @ObservedObject var account: AccountService
    @State private var alias = ""
    @State private var isPublic = false
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if account.signedIn {
                ExplainRow("Sync", value: store.syncStatus)
                Button(store.isSyncing ? "Syncing…" : "Sync now") { Task { await store.syncNow() } }.disabled(store.isSyncing)
                NavigationLink("Signed-in devices") { DevicesView(account: account).environment(\.theme, theme) }
                Button("Sign out on this device") { confirmSignOut = true }
                Button("Delete account…", role: .destructive) { confirmDelete = true }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    account.prepare(request)
                } onCompletion: { result in
                    Task { if let message = await account.complete(result) { store.notice = message } }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .disabled(account.busy)
                GoogleSignInButton(account: account) { store.notice = $0 }
                EmailSignInView(account: account) { store.notice = $0 }
                if account.busy { ProgressView() }
            }
        } header: {
            Text("Account & sync")
        } footer: {
            Text(account.signedIn
                 ? "Your portfolios, journal and notes sync to every device signed in to this account. Changes made on two devices are merged."
                 : "Optional. Sync your practice workspace across iPhone and Mac with Apple, Google or your email. Nothing is public unless you turn it on below.")
        }
        .onAppear { alias = account.alias ?? ""; isPublic = account.isPublic }
        .onChange(of: account.alias) { _, value in alias = value ?? "" }
        .onChange(of: account.isPublic) { _, value in isPublic = value }
        .confirmationDialog("Sign out on this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out") { Task { await store.syncNow(); await account.signOut() } }
        } message: { Text("Your practice data stays on this device. Sign in again any time to resume syncing.") }
        .confirmationDialog("Delete your Trading Lab account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task {
                    if let message = await account.deleteAccount() { store.notice = message }
                    else { store.notice = "Your account, synced copy and public record were deleted. Practice data on this device was kept." }
                }
            }
        } message: {
            Text("This deletes the synced copy, your public record and every signed-in session, and disconnects Sign in with Apple. Data on this device stays.")
        }

        if account.signedIn {
            Section {
                Toggle("Show me on practice records", isOn: $isPublic)
                if isPublic {
                    TextField("Nickname (2–24 characters)", text: $alias).appCapitalization(.words).autocorrectionDisabled()
                }
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        let cleaned = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let message = await store.setPublicRecord(alias: cleaned.isEmpty ? nil : cleaned, isPublic: isPublic) { store.notice = message }
                        else { store.showToast(isPublic ? "Your record is public." : "Your record is private.") }
                        saving = false
                    }
                }.disabled(saving || (isPublic == account.isPublic && (alias == (account.alias ?? "") || !isPublic)))
                Link("View practice records", destination: AppConfig.recordsURL)
            } header: {
                Text("Public record")
            } footer: {
                Text("Off by default. When on, the records page shows only your nickname and your main portfolio's return since start. Holdings, orders, cash and notes are never published.")
            }
        }
    }
}

struct DevicesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var account: AccountService
    @State private var sessions: [RemoteSession]?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                if let sessions {
                    ForEach(sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: Space.s4) {
                                Text(session.deviceName + (session.current ? " · this device" : ""))
                                Text("Last active \(Parse.iso8601(session.lastUsedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                                    .font(theme.meta).foregroundStyle(theme.muted)
                            }
                            Spacer()
                            if !session.current {
                                Button("Sign out", role: .destructive) {
                                    Task { if await account.revoke(session: session.id) { await load() } }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                } else if failed {
                    Text("Devices could not be loaded.").foregroundStyle(theme.muted)
                } else {
                    ProgressView()
                }
            } footer: {
                Text("Signing out a device ends its session immediately. Its local practice data is not deleted.")
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Devices")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let loaded = await account.sessions()
        sessions = loaded
        failed = loaded == nil
    }
}

struct UserPreferenceSections: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @AppStorage(PreferenceKeys.theme) private var themeName = AppTheme.botanical.rawValue
    @AppStorage(PreferenceKeys.appearance) private var appearance = "System"
    @AppStorage(PreferenceKeys.largerText) private var largerText = false
    @AppStorage(PreferenceKeys.accessibleColors) private var accessibleColors = false
    @State private var aiKey = ""
    @State private var hasAIKey = AIImpactModel.hasKey

    var body: some View {
        Section("Appearance & reading") {
            Picker("Theme", selection: $themeName) { ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0.rawValue) } }
            Text("Stock charts keep green and red movement colors. Ethereal blue gives Today a cool blue atmosphere.").font(theme.meta).foregroundStyle(theme.muted)
            Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                .disabled(AppTheme(rawValue: themeName)?.forcedScheme != nil)
            Toggle("Larger text", isOn: $largerText)
            Toggle("Blue / orange gain and loss colors", isOn: $accessibleColors)
        }
        Section("Your Home page") {
            ForEach(TodaySection.allCases, id: \.self) { section in
                Toggle("Show " + section.rawValue.lowercased(), isOn: Binding(
                    get: { store.features.todaySections.contains(section) },
                    set: { store.setTodaySection(section, visible: $0) }))
            }
        }
        Section("AI explanations") {
            SecureField("Gemini API key", text: $aiKey).appCapitalization(.never).autocorrectionDisabled()
            Button("Save AI key") {
                Keychain.save(aiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .gemini)
                aiKey = ""; hasAIKey = AIImpactModel.hasKey
                store.showToast("AI key saved in this device’s Keychain.")
            }.disabled(aiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasAIKey {
                Button("Remove AI key", role: .destructive) { Keychain.delete(.gemini); hasAIKey = false; store.showToast("AI key removed.") }
            }
            Text("Optional. Explanations send the headline, publisher summary and ticker to Gemini using your key. Models: \(AppConfig.geminiModels.joined(separator: ", ")).")
                .font(theme.meta).foregroundStyle(theme.muted)
        }
    }
}

struct ProfileTools: View {
    @ObservedObject var store: LabStore
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            FeatureLink(title: "Portfolios") { PortfolioManagerView(store: store) }
            FeatureLink(title: "Learning goal & challenges") { GuidedPracticeView(store: store) }
            FeatureLink(title: "Journal & exports") { JournalView(store: store) }
            FeatureLink(title: "Share your progress") { ProgressShareView(store: store) }
            FeatureLink(title: "Home-screen snapshot") { WidgetPreviewView(store: store, market: store.market) }
            FeatureLink(title: "Market glossary") { GlossaryView() }
        }
    }
}

struct ProgressCard: View {
    let name: String
    let lessons: Int
    let challenges: Int
    let value: Decimal?
    let showBalance: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TRADING LAB").font(.system(size: 12, weight: .medium)).tracking(2)
            Rectangle().fill(Color(red: 0.84, green: 0.86, blue: 0.82)).frame(height: 1)
            Text(name).font(.system(size: 28)).lineLimit(2)
            Text("Learning through practice.").font(.system(size: 17))
            Text("\(lessons) concept checks complete\n\(challenges) practice challenges complete").font(.system(size: 16)).lineSpacing(6)
            if showBalance {
                Text(value.map(Format.money) ?? "Value pending").font(.system(size: 30)).monospacedDigit()
                Text("Virtual portfolio").font(.system(size: 12))
            }
            Text("Practice money · progress in reasoning").font(.system(size: 12))
        }
        .padding(24).frame(width: 330, alignment: .leading)
        .foregroundStyle(Color(red: 0.11, green: 0.15, blue: 0.14))
        .background(Color(red: 0.985, green: 0.984, blue: 0.975))
    }
}

struct ProgressShareView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var showBalance = false
    @State private var name = "My practice progress"
    @State private var imageURL: URL?

    private var card: ProgressCard {
        ProgressCard(name: name, lessons: store.data.completedChecks.count + store.features.completedBites.count,
                     challenges: store.challenges.filter(\.complete).count, value: store.portfolioValue, showBalance: showBalance)
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Share your progress").font(theme.page)
                TextField("Display title", text: $name).inputField()
                Toggle("Include virtual portfolio value", isOn: $showBalance)
                ViewThatFits(in: .horizontal) {
                    card
                    card.scaleEffect(0.8, anchor: .topLeading).frame(width: 264, height: showBalance ? 310 : 230)
                }
                ActionButton(title: "Prepare image") { renderCard() }
                if let imageURL { ShareLink("Share progress image", item: imageURL).font(theme.label) }
                ShareLink("Share progress text", item: "Trading Lab: \(store.data.completedChecks.count + store.features.completedBites.count) concept checks and \(store.challenges.filter(\.complete).count) practice challenges complete.")
            }
        }
        .navigationTitle("Share progress").appInlineTitle()
        .onChange(of: showBalance) { _, _ in imageURL = nil }
        .onChange(of: name) { _, _ in imageURL = nil }
    }

    private func renderCard() {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Trading-Lab-Progress-\(UUID().uuidString).png")
        #if os(iOS)
        let bytes = renderer.uiImage?.pngData()
        #else
        let bytes = renderer.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        #endif
        guard let bytes else { store.notice = "The progress image could not be created."; return }
        do { try bytes.write(to: destination); imageURL = destination }
        catch { store.notice = "The progress image could not be saved." }
    }
}

struct WidgetPreviewView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Home-screen snapshot").font(theme.page)
                VStack(alignment: .leading, spacing: Space.s12) {
                    Eyebrow(text: store.activeTitle)
                    AnimatedMoney(value: store.portfolioValue?.double, font: theme.page)
                    Text(store.data.watched.prefix(4).joined(separator: " · ")).font(theme.label)
                    Rule()
                    Text("Next: \(store.nextLearningTitle)").font(theme.meta)
                }
                .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
                .overlay(RoundedRectangle(cornerRadius: Space.radius).stroke(theme.line))
                Text("The widget shows your last saved snapshot. It updates when you use the app.").foregroundStyle(theme.muted)
                Text("Add Trading Lab from your device’s widget gallery to keep this snapshot close.").font(theme.meta).foregroundStyle(theme.muted)
            }
        }
        .navigationTitle("Snapshot").appInlineTitle()
        .task { store.publishWidget() }
    }
}
