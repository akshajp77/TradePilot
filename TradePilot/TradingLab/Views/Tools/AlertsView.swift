import SwiftUI
import UserNotifications

/// Price, change, VWAP, RSI and relative-volume alerts.
struct AlertsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var initialSymbol: String? = nil

    enum Kind: String, CaseIterable {
        case priceAbove = "Price rises to", priceBelow = "Price falls to"
        case changeAbove = "Change % at least", changeBelow = "Change % at most"
        case vwapAbove = "Crosses above VWAP", vwapBelow = "Crosses below VWAP"
        case rsiAbove = "RSI above", rsiBelow = "RSI below", rvol = "Relative volume above"
        var needsValue: Bool { self != .vwapAbove && self != .vwapBelow }
        var placeholder: String {
            switch self {
            case .priceAbove, .priceBelow: return "Price"
            case .changeAbove, .changeBelow: return "Percent, e.g. 5 or -3"
            case .rsiAbove: return "e.g. 70"
            case .rsiBelow: return "e.g. 30"
            case .rvol: return "e.g. 2"
            default: return ""
            }
        }
    }

    @State private var symbol = ""
    @State private var kind: Kind = .priceAbove
    @State private var value = ""
    @State private var repeats = false
    @State private var note = ""

    private var condition: AlertCondition? {
        let decimal = DecimalInput.parse(value)
        let number = decimal?.double
        switch kind {
        case .priceAbove: if let d = decimal, d > 0 { return AlertCondition.priceAbove(d) }
        case .priceBelow: if let d = decimal, d > 0 { return AlertCondition.priceBelow(d) }
        case .changeAbove: if let n = number { return AlertCondition.changeAbove(n) }
        case .changeBelow: if let n = number { return AlertCondition.changeBelow(n) }
        case .vwapAbove: return AlertCondition.crossesAboveVWAP
        case .vwapBelow: return AlertCondition.crossesBelowVWAP
        case .rsiAbove: if let n = number, (1...99).contains(n) { return AlertCondition.rsiAbove(n) }
        case .rsiBelow: if let n = number, (1...99).contains(n) { return AlertCondition.rsiBelow(n) }
        case .rvol: if let n = number, n > 0 { return AlertCondition.relativeVolumeAbove(n) }
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Picker("Symbol", selection: $symbol) { ForEach(store.allSecurities) { Text($0.symbol).tag($0.symbol) } }
                Picker("When", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if kind.needsValue {
                    TextField(kind.placeholder, text: $value).appNumberKeyboard(.decimal)
                }
                if let price = store.market.price(symbol) {
                    ExplainRow("Now", value: "\(Format.price(price))" + (store.market.change(symbol).map { " · " + Format.percent($0 / 100) } ?? ""), symbol: symbol)
                }
                Toggle("Repeat (re-arms after 15 minutes)", isOn: $repeats)
                TextField("Note, e.g. the plan if it triggers", text: $note)
                Button("Create alert") {
                    guard let condition else { return }
                    store.addAlert(symbol: symbol, condition: condition, repeats: repeats, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                    value = ""; note = ""
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                }
                .disabled(condition == nil || symbol.isEmpty)
            } header: {
                Text("New alert")
            } footer: {
                Text("Alerts are checked on every price while the app is running. VWAP, RSI and relative volume use 5-minute bars during the regular session.")
            }
            Section("Your alerts") {
                if store.features.alerts.isEmpty { Text("No alerts yet.").foregroundStyle(theme.muted) }
                ForEach(store.features.alerts.sorted { $0.createdAt > $1.createdAt }) { alert in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(alert.symbol) · \(alert.condition.title)").font(theme.label)
                            if !alert.note.isEmpty { Text(alert.note).font(theme.meta) }
                            Text(status(alert)).font(theme.meta).foregroundStyle(alert.triggeredAt == nil ? theme.muted : theme.warning)
                        }
                        Spacer()
                        if alert.triggeredAt != nil && !alert.repeats {
                            Button("Re-arm") { store.rearmAlert(alert.id) }.font(theme.meta).buttonStyle(.borderless)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { store.removeAlert(alert.id) } }
                    .contextMenu {
                        Button("Open chart") { store.openChart(alert.symbol) }
                        Button("Delete", role: .destructive) { store.removeAlert(alert.id) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Alerts")
        .onAppear { if symbol.isEmpty { symbol = initialSymbol ?? store.chartSymbol } }
    }

    private func status(_ alert: PriceAlert) -> String {
        guard let triggered = alert.triggeredAt else { return alert.repeats ? "Armed · repeats" : "Armed" }
        return "Triggered \(triggered.formatted(date: .abbreviated, time: .shortened))" + (alert.repeats ? " · re-arms" : "")
    }
}
