import SwiftUI

/// Market scanner: day-trading presets with liquidity filters. Tap a row to chart it.
struct ScannerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    @AppStorage("scanner-preset") private var presetName = ScanPreset.gainers.rawValue
    @State private var rows: [ScanRow] = []
    @State private var loading = false
    @State private var failed = false
    @State private var filter = ScanFilter.dayTrading
    @State private var editingFilter = false
    @State private var sort: Sort = .preset
    @State private var updatedAt: Date?
    @State private var opening: String?

    enum Sort: String, CaseIterable { case preset = "Preset", change = "% Chg", volume = "Volume", rvol = "RVOL", gap = "Gap", price = "Price" }

    private var preset: ScanPreset { ScanPreset(rawValue: presetName) ?? .gainers }

    private var shown: [ScanRow] {
        let filtered = rows.filter(filter.matches)
        switch sort {
        case .preset: return filtered
        case .change: return filtered.sorted { abs($0.changePercent) > abs($1.changePercent) }
        case .volume: return filtered.sorted { ($0.volume ?? 0) > ($1.volume ?? 0) }
        case .rvol: return filtered.sorted { ($0.relativeVolume ?? 0) > ($1.relativeVolume ?? 0) }
        case .gap: return filtered.sorted { abs($0.gapPercent ?? 0) > abs($1.gapPercent ?? 0) }
        case .price: return filtered.sorted { $0.price > $1.price }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s8) {
                    ForEach(ScanPreset.allCases) { p in
                        Button(p.rawValue) { presetName = p.rawValue }
                            .font(theme.meta.weight(p == preset ? .semibold : .regular))
                            .padding(.horizontal, Space.s12).frame(height: 32)
                            .foregroundStyle(p == preset ? theme.ink : theme.muted)
                            .background(p == preset ? theme.surface : theme.line.opacity(0.22), in: Capsule())
                            .overlay(Capsule().stroke(p == preset ? theme.accent.opacity(0.4) : .clear, lineWidth: 1))
                            .buttonStyle(.plain)
                    }
                }.padding(.horizontal, Space.s16).padding(.vertical, Space.s8)
            }
            HStack {
                Text(preset.detail).font(theme.meta).foregroundStyle(theme.muted)
                ExplainButton(term: "Relative volume", size: 12)
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Label(sort.rawValue, systemImage: "arrow.up.arrow.down").font(theme.meta) }
                Button { editingFilter = true } label: {
                    Label(filter.isActive ? "Filters on" : "Filters", systemImage: "line.3.horizontal.decrease.circle\(filter.isActive ? ".fill" : "")")
                        .font(theme.meta)
                }
            }
            .padding(.horizontal, Space.s16).padding(.bottom, Space.s8)
            Rule()
            header
            Rule()
            if loading && rows.isEmpty {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && rows.isEmpty {
                VStack(spacing: Space.s8) {
                    Text("The scanner couldn't reach the market data source.").font(theme.label)
                    Button("Try again") { Task { await load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shown) { row in
                        Button { open(row.symbol) } label: { ScanRowView(row: row, opening: opening == row.symbol) }
                            .buttonStyle(.plain)
                            .listRowBackground(theme.paper)
                            .listRowInsets(EdgeInsets(top: 0, leading: Space.s16, bottom: 0, trailing: Space.s16))
                            .contextMenu {
                                Button("Open chart") { open(row.symbol) }
                                Button("Add to watchlist") { Task { if await store.ensureSecurity(row.symbol) != nil, !store.data.watched.contains(row.symbol) { store.toggleWatch(row.symbol) } } }
                                Button("Alert at +5% from here") {
                                    Task { if await store.ensureSecurity(row.symbol) != nil {
                                        store.addAlert(symbol: row.symbol, condition: .priceAbove(Decimal.price(row.price * 1.05).tickRounded))
                                    } }
                                }
                            }
                    }
                    if shown.isEmpty {
                        Text(rows.isEmpty ? "No results." : "\(rows.count) results hidden by your filters.").font(theme.label).foregroundStyle(theme.muted)
                            .listRowBackground(theme.paper)
                    }
                    if let updatedAt {
                        Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened)) · \(Feeds.alpacaCredentials != nil && [.gainers, .losers, .active].contains(preset) ? "Alpaca screener" : "Yahoo screener, may be delayed") · \"Vol ×\" is today's volume compared with a normal day (3-month average)")
                            .font(theme.meta).foregroundStyle(theme.muted).listRowBackground(theme.paper)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .background(theme.paper.ignoresSafeArea())
        .navigationTitle("Scanner")
        .task(id: presetName) { await load() }
        .task {
            // Refresh every minute while visible during market sessions.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if market.hours.sessionKind(at: Date()) != .closed { await load() }
            }
        }
        .sheet(isPresented: $editingFilter) { ScanFilterEditor(filter: $filter).environment(\.theme, theme) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Symbol").frame(maxWidth: .infinity, alignment: .leading)
            Text("Price").frame(width: 64, alignment: .trailing)
            Text("% Chg").frame(width: 62, alignment: .trailing)
            Text("Vol").frame(width: 52, alignment: .trailing)
            Text("Vol ×").frame(width: 46, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.muted)
        .padding(.horizontal, Space.s16).padding(.vertical, 6)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let result = await market.scan(preset) {
            rows = result
            failed = false
            updatedAt = Date()
            store.recordAction("scanner")
        } else {
            failed = true
        }
    }

    private func open(_ symbol: String) {
        opening = symbol
        Task {
            if await store.ensureSecurity(symbol) != nil { store.openChart(symbol) }
            opening = nil
        }
    }
}

private struct ScanRowView: View {
    @Environment(\.theme) private var theme
    let row: ScanRow
    let opening: Bool
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.symbol).font(theme.label).holdToExplainSymbol(row.symbol)
                    if opening { ProgressView().controlSize(.mini) }
                }
                Text(row.name).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.price(row.price)).frame(width: 64, alignment: .trailing)
                .holdToExplain("Last price", value: Format.price(row.price), symbol: row.symbol)
            Text(String(format: "%+.1f%%", row.changePercent)).foregroundStyle(theme.movement(row.changePercent >= 0)).frame(width: 62, alignment: .trailing)
                .holdToExplain("Change today", value: String(format: "%+.1f%%", row.changePercent), symbol: row.symbol, tone: theme.movement(row.changePercent >= 0))
            Text(row.volume.map(Format.compact) ?? "—").frame(width: 52, alignment: .trailing)
                .holdToExplain("Volume", value: row.volume.map(Format.compact) ?? "—", symbol: row.symbol)
            Text(row.relativeVolume.map { String(format: "%.1f", $0) } ?? "—")
                .foregroundStyle((row.relativeVolume ?? 0) >= 2 ? theme.orange : theme.ink)
                .frame(width: 46, alignment: .trailing)
                .holdToExplain("Relative volume", value: row.relativeVolume.map { String(format: "%.1f×", $0) } ?? "—", symbol: row.symbol, context: ["Above 2× means trading is unusually busy today."])
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the chart")
    }
}

private struct ScanFilterEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: ScanFilter

    var body: some View {
        NavigationStack {
            Form {
                Section("Price") {
                    field("Minimum price", value: $filter.minPrice)
                    field("Maximum price", value: $filter.maxPrice)
                }
                Section("Liquidity") {
                    field("Minimum volume (shares)", value: $filter.minVolume)
                    field("Minimum volume vs normal (×)", value: $filter.minRelativeVolume)
                    field("Minimum market cap ($)", value: $filter.minMarketCap)
                }
                Section("Movement") {
                    field("Minimum move (%, either way)", value: $filter.minAbsChange)
                }
                Section {
                    Button("Day-trading defaults ($2+, 1M+ volume)") { filter = .dayTrading }
                    Button("Clear filters", role: .destructive) { filter = ScanFilter() }
                } footer: {
                    Text("Low-priced, thinly traded stocks have wide spreads and fast moves both ways. The defaults screen them out.")
                }
            }
            .scrollContentBackground(.hidden).background(theme.paper)
            .navigationTitle("Filters").appInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func field(_ title: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Any", text: Binding(
                get: { value.wrappedValue.map { $0.formatted(.number.grouping(.never)) } ?? "" },
                set: { value.wrappedValue = DecimalInput.parse($0)?.double }))
            .appNumberKeyboard(.decimal).multilineTextAlignment(.trailing).frame(maxWidth: 120)
        }
    }
}
