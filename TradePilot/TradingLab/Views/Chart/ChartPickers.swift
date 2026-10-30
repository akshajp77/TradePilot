import SwiftUI

/// Search the catalog, your watchlist, or any US ticker.
struct SymbolPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    let choose: (String) -> Void
    @State private var query = ""
    @State private var looking = false

    private var matches: [Security] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.allSecurities
        guard !q.isEmpty else {
            let pinned = Set(store.data.watched + store.heldSymbols)
            return all.filter { pinned.contains($0.symbol) } + all.filter { !pinned.contains($0.symbol) }
        }
        return all.filter { $0.symbol.lowercased().hasPrefix(q) || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                let typed = query.trimmingCharacters(in: .whitespaces).uppercased()
                if !typed.isEmpty, store.security(typed) == nil {
                    Button {
                        looking = true
                        Task {
                            if let item = await store.ensureSecurity(typed) { choose(item.symbol); dismiss() }
                            looking = false
                        }
                    } label: {
                        HStack { Label("Look up \(typed)", systemImage: "magnifyingglass"); Spacer(); if looking { ProgressView() } }
                    }
                }
                ForEach(matches) { item in
                    Button { choose(item.symbol); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.symbol).font(theme.label).holdToExplainSymbol(item.symbol)
                                Text(item.name).font(theme.meta).foregroundStyle(theme.muted).lineLimit(1)
                            }
                            Spacer()
                            if let price = market.price(item.symbol) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Format.price(price)).font(theme.label.monospacedDigit())
                                        .holdToExplain("Last price", value: Format.price(price), symbol: item.symbol)
                                    if let change = market.change(item.symbol) {
                                        Text(Format.percent(change / 100)).font(theme.meta.monospacedDigit()).foregroundStyle(theme.movement(change >= 0))
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Symbol or company")
            .scrollContentBackground(.hidden).background(theme.paper)
            .navigationTitle("Symbol").appInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Add, remove and tune chart indicators.
struct IndicatorEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: ChartPreferences

    var body: some View {
        NavigationStack {
            List {
                Section("On the chart") {
                    if preferences.indicators.isEmpty { Text("No indicators.").foregroundStyle(theme.muted) }
                    ForEach($preferences.indicators) { $config in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(ChartPalette.color(config.colorIndex)).frame(width: 10, height: 10)
                                Text(config.title).font(theme.label)
                                Spacer()
                                Button { config.colorIndex += 1 } label: { Image(systemName: "paintpalette") }.buttonStyle(.borderless)
                                    .accessibilityLabel("Change color")
                            }
                            if config.kind != .vwap && config.kind != .macd {
                                Stepper("Length \(config.length)", value: $config.length, in: 2...400)
                                    .font(theme.meta)
                            }
                            Text(config.kind.explanation).font(theme.meta).foregroundStyle(theme.muted)
                        }
                    }
                    .onDelete { preferences.indicators.remove(atOffsets: $0) }
                    .onMove { preferences.indicators.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Add") {
                    ForEach(IndicatorKind.allCases) { kind in
                        HStack {
                            Button {
                                preferences.indicators.append(IndicatorConfig(kind: kind, colorIndex: preferences.indicators.count))
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text(kind.rawValue)
                                    Spacer()
                                    Text(kind.isOverlay ? "On the price" : "Below the chart").font(theme.meta).foregroundStyle(theme.muted)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(kind == .vwap && preferences.indicators.contains { $0.kind == .vwap })
                            ExplainButton(term: kind.rawValue)
                        }
                    }
                }
                Section {
                    Button("Day-trading default (VWAP, EMA 9, EMA 20)") { preferences.indicators = ChartPreferences().indicators }
                    Button("Clear all", role: .destructive) { preferences.indicators = [] }
                }
            }
            .scrollContentBackground(.hidden).background(theme.paper)
            .navigationTitle("Indicators").appInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
