import SwiftUI

/// Account rules, fill realism and risk guardrails for the practice brokerage.
struct TradingSettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var lossLimit = ""
    @State private var maxPosition = ""
    @State private var riskPercent = ""
    @State private var slippage = ""
    @State private var perOrder = ""
    @State private var perShare = ""
    @State private var maintenance = ""

    private var s: TradingSettings { store.settings }

    var body: some View {
        Form {
            Section {
                Picker("Account type", selection: binding(\.accountType)) { ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .disabled(!store.isUnlocked(.margin))
                    .holdToExplain("Account type", value: s.accountType.rawValue)
                if !store.isUnlocked(.margin) {
                    Text("Margin unlocks after the lesson \"\(Curriculum.content.lesson(unlocking: .margin)?.title ?? "Margin")\" in Learn.").font(theme.meta).foregroundStyle(theme.muted)
                }
                if s.accountType == .margin {
                    Toggle("Allow short selling", isOn: binding(\.shortingEnabled)).disabled(!store.isUnlocked(.shorting))
                    Picker("Day-trading rule", selection: binding(\.regime)) { ForEach(MarginRegime.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .holdToExplain("Day-trading rule", value: s.regime.rawValue)
                    decimalField("Maintenance margin %", text: $maintenance) { value in
                        guard let value, value >= 25, value <= 100 else { return }
                        store.updateSettings { $0.maintenanceRate = value / 100 }
                    }
                }
            } header: { Text("Account") } footer: { Text(accountFooter) }

            Section {
                Picker("Fills", selection: binding(\.fillModel)) { ForEach(FillModel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .holdToExplain("Fills", value: s.fillModel.rawValue)
                if s.fillModel == .realistic {
                    decimalField("Market-order slippage (bps)", text: $slippage) { value in
                        guard let value, value >= 0, value <= 100 else { return }
                        store.updateSettings { $0.slippageBps = value }
                    }
                }
                decimalField("Commission per order ($)", text: $perOrder) { value in store.updateSettings { $0.commissionPerOrder = max(0, value ?? 0) } }
                decimalField("Commission per share ($)", text: $perShare) { value in store.updateSettings { $0.commissionPerShare = max(0, value ?? 0) } }
            } header: { Text("Executions") } footer: {
                Text(s.fillModel == .realistic
                     ? "Buys pay the ask and sells get the bid (IEX quote when connected, otherwise a modeled spread of at least half a cent). Market and stop orders add slippage. Limits fill only when the price trades through."
                     : "Fills at the last trade price. Optimistic: real fills cross the spread.")
            }

            Section {
                decimalField("Daily loss limit ($)", text: $lossLimit) { value in store.updateSettings { $0.dailyLossLimit = value.flatMap { $0 > 0 ? $0 : nil } } }
                decimalField("Max position (% of equity)", text: $maxPosition) { value in
                    store.updateSettings { $0.maxPositionFraction = value.flatMap { $0 > 0 && $0 <= 400 ? $0 / 100 : nil } }
                }
                decimalField("Default risk per trade (%)", text: $riskPercent) { value in
                    guard let value, value > 0, value <= 10 else { return }
                    store.updateSettings { $0.riskFraction = value / 100 }
                }
                Toggle("Require a stop on every entry", isOn: binding(\.requireStop))
                Toggle("Confirm before sending orders", isOn: binding(\.confirmOrders))
            } header: { Text("Risk guardrails") } footer: {
                Text("Leave a field empty to turn it off. The loss limit locks new positions for the rest of the session once today's P&L reaches it; closing trades are always allowed.")
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Trading rules")
        .onAppear(perform: load)
    }

    private var accountFooter: String {
        switch (s.accountType, s.regime) {
        case (.cash, _):
            return "Cash account: you trade settled cash only. Sale proceeds settle the next business day (T+1), and short selling isn't allowed. No day-trade limits."
        case (.margin, .intraday2026):
            return "FINRA's amended Rule 4210 (effective June 4, 2026) replaced the pattern day trader rule: no $25,000 minimum and no 4-trades-in-5-days count. Instead, margin is checked intraday and a trade that would leave you below maintenance is blocked. Buying power is 2× excess equity (Reg T 50%); under $2,000 equity there is no leverage or shorting."
        case (.margin, .legacyPDT):
            return "The old pattern day trader rule, which brokers may keep using until October 20, 2027: under $25,000 equity, a 4th day trade within 5 sessions is blocked."
        }
    }

    private func load() {
        maintenance = Format.plain(s.maintenanceRate * 100)
        slippage = Format.plain(s.slippageBps)
        perOrder = s.commissionPerOrder > 0 ? Format.plain(s.commissionPerOrder) : ""
        perShare = s.commissionPerShare > 0 ? Format.plain(s.commissionPerShare) : ""
        lossLimit = s.dailyLossLimit.map(Format.plain) ?? ""
        maxPosition = s.maxPositionFraction.map { Format.plain($0 * 100) } ?? ""
        riskPercent = Format.plain(s.riskFraction * 100)
    }

    private func binding<T>(_ key: WritableKeyPath<TradingSettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: key] }, set: { value in store.updateSettings { $0[keyPath: key] = value } })
    }

    private func decimalField(_ title: String, text: Binding<String>, commit: @escaping (Decimal?) -> Void) -> some View {
        HStack {
            Text(title)
                .holdToExplain(title, value: text.wrappedValue.isEmpty ? "Off" : text.wrappedValue)
            Spacer()
            TextField("Off", text: text)
                .appNumberKeyboard(.decimal).multilineTextAlignment(.trailing).frame(maxWidth: 110)
                .onChange(of: text.wrappedValue) { _, newValue in commit(DecimalInput.parse(newValue)) }
        }
    }
}
