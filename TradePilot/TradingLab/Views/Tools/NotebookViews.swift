import SwiftUI
import Charts
import UserNotifications

struct ResearchNoteEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LabStore
    let article: NewsArticle
    var symbol: String
    @State private var note = ""
    @State private var quote = ""
    @State private var ticker = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved research") {
                    Text(article.cleanTitle).font(theme.label)
                    TextField("Related ticker", text: $ticker).appCapitalization(.characters)
                    Text("Paste a short passage from the publisher's page to keep a highlight.").font(theme.meta)
                    TextField("Highlighted passage", text: $quote, axis: .vertical).lineLimit(3...8)
                    TextField("Your notes", text: $note, axis: .vertical).lineLimit(5...12)
                }
                Button("Save research") {
                    store.saveResearch(SavedResearch(title: article.cleanTitle, source: article.source, url: article.url, date: article.date,
                                                     symbol: ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), note: note, quote: quote))
                    dismiss()
                }
            }
            .scrollContentBackground(.hidden).background(theme.paper)
            .navigationTitle("Research notes").appInlineTitle()
            .toolbar { ToolbarItem { Button("Close") { dismiss() } } }
        }
        .onAppear {
            ticker = symbol
            if let saved = store.features.research.first(where: { $0.url == article.url }) { note = saved.note; quote = saved.quote; ticker = saved.symbol }
        }
    }
}

struct ResearchLibraryView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var focus: String? = nil
    @State private var query = ""
    @State private var note = ""
    @State private var editing: SavedResearch?

    private var records: [SavedResearch] {
        store.features.research.filter {
            (focus == nil || $0.symbol == focus) && (query.isEmpty || ($0.title + $0.note + $0.quote + $0.symbol).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text(focus.map { "\($0) notebook" } ?? "Saved research").font(theme.page)
                TextField("Search titles, notes, or tickers", text: $query).inputField()
                if let focus {
                    TextField("Add a research note", text: $note, axis: .vertical).lineLimit(3...8).inputField()
                    Button("Save note") {
                        store.saveResearch(SavedResearch(title: "\(focus) research note", source: "Your notebook",
                                                         url: URL(string: "tradinglab://note/" + UUID().uuidString)!,
                                                         date: Date(), symbol: focus, note: note))
                        note = ""
                    }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Rule()
                if records.isEmpty { Text("Save a story from News, or write a note from a stock’s notebook.").foregroundStyle(theme.muted) }
                ForEach(records) { saved in
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Eyebrow(text: saved.symbol.isEmpty ? saved.source : saved.symbol + " · " + saved.source)
                        if saved.url.scheme == "https" {
                            NavigationLink {
                                ArticleView(article: article(for: saved), focusSymbol: saved.symbol.isEmpty ? nil : saved.symbol)
                            } label: { Text(saved.title).font(theme.section).foregroundStyle(theme.ink).multilineTextAlignment(.leading) }
                        } else {
                            Text(saved.title).font(theme.section)
                        }
                        if !saved.quote.isEmpty {
                            Text(saved.quote).font(.custom("Charter", size: 17, relativeTo: .body)).padding(Space.s12)
                                .frame(maxWidth: .infinity, alignment: .leading).background(theme.line.opacity(0.3))
                        }
                        if !saved.note.isEmpty { Text(saved.note).textSelection(.enabled) }
                        HStack {
                            Button("Edit note") { editing = saved }
                            Spacer()
                            Button("Remove", role: .destructive) { store.removeResearch(saved.id) }
                        }.font(theme.meta)
                        Rule()
                    }
                }
            }
        }
        .navigationTitle("Research").appInlineTitle()
        .sheet(item: $editing) { saved in
            ResearchNoteEditor(store: store, article: article(for: saved), symbol: saved.symbol).environment(\.theme, theme)
        }
    }

    private func article(for saved: SavedResearch) -> NewsArticle {
        NewsArticle(title: saved.title, source: saved.source, date: saved.date, url: saved.url, symbols: saved.symbol.isEmpty ? [] : [saved.symbol])
    }
}

struct JournalView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var query = ""
    @State private var strategy = "All"

    private var orders: [PracticeOrder] {
        store.data.orders.filter { order in
            let note = store.features.tradeNotes[order.id.uuidString] ?? TradeNote()
            return (strategy == "All" || note.strategy == strategy)
                && (query.isEmpty || (order.symbol + order.thesis + order.reflection + note.emotion).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Your journal").font(theme.page)
                TextField("Search ticker, reasoning, or reflection", text: $query).inputField()
                Picker("Strategy", selection: $strategy) { Text("All").tag("All"); ForEach(TradeNote.strategies, id: \.self) { Text($0) } }
                if orders.isEmpty { Text("No entries match. Your practice trades appear here automatically.").foregroundStyle(theme.muted) }
                ForEach(orders) { order in
                    FeatureLink(title: "\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol)",
                                detail: (store.features.tradeNotes[order.id.uuidString]?.strategy ?? "Uncategorized") + " · " + order.status.rawValue) {
                        JournalEntryView(store: store, id: order.id)
                    }
                    Rule()
                }
                FeatureLink(title: "Export your journal") { JournalExportView(store: store) }
            }
        }.navigationTitle("Journal").appInlineTitle()
    }
}

struct JournalEntryView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    let id: UUID
    @State private var note = TradeNote()
    @State private var reflection = ""
    private var order: PracticeOrder? { store.data.orders.first { $0.id == id } }

    var body: some View {
        Form {
            if let order {
                Section("Original decision") {
                    Text("\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol)").font(theme.section)
                    Text(order.thesis.isEmpty ? "No thesis recorded." : order.thesis)
                    Text("Change my mind if: \(order.invalidation)")
                    Text("Horizon: \(order.horizon)")
                }
                Section("Decision context") {
                    Picker("Strategy", selection: $note.strategy) { ForEach(TradeNote.strategies, id: \.self) { Text($0) } }
                    Stepper("Original confidence: \(note.confidence) of 5", value: $note.confidence, in: 1...5)
                    Picker("Emotion", selection: $note.emotion) { ForEach(TradeNote.emotions, id: \.self) { Text($0) } }
                    Picker("Followed my plan", selection: $note.followedPlan) {
                        Text("Not reviewed").tag(Bool?.none)
                        Text("Yes").tag(Bool?.some(true))
                        Text("No").tag(Bool?.some(false))
                    }
                    TextField("Reflection", text: $reflection, axis: .vertical).lineLimit(4...12)
                }
                Section("Chart snapshot") {
                    if !note.chart.isEmpty {
                        Chart(Array(note.chart.enumerated()), id: \.offset) { entry in
                            LineMark(x: .value("Observation", entry.offset), y: .value("Price", entry.element)).foregroundStyle(theme.accent)
                        }.frame(height: 160)
                        Text("Saved price observations, captured when you tapped Save snapshot.").font(theme.meta)
                    }
                    Button("Save current chart snapshot") {
                        note.chart = Array(store.market.points(order.symbol, range: .month).map(\.price).suffix(60))
                        if note.chart.isEmpty { store.notice = "Price history is unavailable. Open the stock chart and try again." }
                    }
                }
                Button("Save entry") {
                    store.setNote(note, for: id)
                    store.reflect(id, text: reflection.trimmingCharacters(in: .whitespacesAndNewlines))
                    store.showToast("Journal entry saved.")
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Trade reflection")
        .onAppear {
            note = store.features.tradeNotes[id.uuidString] ?? TradeNote()
            reflection = order?.reflection ?? ""
        }
        .task { if let order { await store.market.loadSeries(order.symbol, range: .month) } }
    }
}

struct JournalExportView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var csv: URL?
    @State private var report: URL?
    @State private var error: String?

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Export journal").font(theme.page)
                Text("\(store.activeTitle) · \(store.data.orders.count) orders").foregroundStyle(theme.muted)
                if let csv { ShareLink("Export CSV", item: csv).font(theme.label) }
                if let report { ShareLink("Export readable report", item: report).font(theme.label) }
                if let error { Text(error).foregroundStyle(theme.loss) }
                Text(store.journalReport).font(theme.meta).textSelection(.enabled)
            }
        }
        .navigationTitle("Export").appInlineTitle()
        .task {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let csvURL = directory.appendingPathComponent("Trading-Lab-Journal.csv")
                let reportURL = directory.appendingPathComponent("Trading-Lab-Journal.txt")
                try store.csvJournal.write(to: csvURL, atomically: true, encoding: .utf8)
                try store.journalReport.write(to: reportURL, atomically: true, encoding: .utf8)
                csv = csvURL
                report = reportURL
            } catch { self.error = "The export could not be created: \(error.localizedDescription)" }
        }
    }
}

struct EventCalendarView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    var initialSymbol = "AAPL"
    @State private var symbol = "AAPL"
    @State private var kind = "Earnings"
    @State private var date = Date()
    @State private var expected = ""
    @State private var actual = ""
    @State private var note = ""
    @State private var editingID: String?

    var body: some View {
        Form {
            Section("Your event calendar") {
                Text("Track dates you verify from company announcements. Expectations and results are your own notes.").font(theme.meta).foregroundStyle(theme.muted)
                ForEach(store.features.events.sorted { $0.date < $1.date }) { event in
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text("\(event.symbol) · \(event.kind)").font(theme.label)
                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(theme.meta)
                        if !event.expected.isEmpty { Text("Expected: \(event.expected)") }
                        if !event.actual.isEmpty { Text("Actual: \(event.actual)") }
                        if !event.note.isEmpty { Text(event.note) }
                        HStack {
                            Button("Edit") {
                                editingID = event.id; symbol = event.symbol; kind = event.kind; date = event.date
                                expected = event.expected; actual = event.actual; note = event.note
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { store.removeEvent(event.id) }
                        }.font(theme.meta).buttonStyle(.borderless)
                    }
                }
            }
            Section(editingID == nil ? "Add verified event" : "Update event") {
                Picker("Ticker", selection: $symbol) { ForEach(store.allSecurities) { Text($0.symbol).tag($0.symbol) } }
                Picker("Event", selection: $kind) { ForEach(["Earnings", "Dividend", "Thesis review", "Other"], id: \.self) { Text($0) } }
                DatePicker("Date and time", selection: $date)
                TextField("Expected, optional", text: $expected)
                TextField("Actual result, optional", text: $actual)
                TextField("Source or notes", text: $note, axis: .vertical)
                Button(editingID == nil ? "Add event" : "Save changes") {
                    let event = TrackedEvent(id: editingID ?? UUID().uuidString, symbol: symbol, kind: kind, date: date, expected: expected, actual: actual, note: note)
                    store.saveEvent(event)
                    Task { await scheduleReminder(event) }
                    clearForm()
                }
                if editingID != nil { Button("Cancel edit") { clearForm() } }
            }
            Section("Alerts") {
                NavigationLink { AlertsView(store: store, initialSymbol: symbol) } label: {
                    ExplainRow("Price & indicator alerts", value: "\(store.features.alerts.count)")
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.paper)
        .navigationTitle("Alerts & events")
        .onAppear { symbol = initialSymbol }
    }

    private func clearForm() { editingID = nil; expected = ""; actual = ""; note = "" }

    private func scheduleReminder(_ event: TrackedEvent) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [event.id])
        guard event.date > Date() else { return }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                store.notice = "Event saved. Enable notifications in system settings to receive reminders."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "\(event.symbol) · \(event.kind)"
            content.body = event.note.isEmpty ? "Review this event in your calendar." : event.note
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.date)
            try await center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        } catch { store.notice = "Event saved; its reminder could not be scheduled." }
    }
}

struct StockFinderView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var resultQuery = ""
    @State private var searching = false
    @State private var failed = false
    @State private var adding: String?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var local: [Security] {
        let words = term.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return store.allSecurities.filter { item in words.allSatisfy { (item.symbol + " " + item.name).localizedCaseInsensitiveContains(String($0)) } }
    }
    private var remote: [SearchResult] { resultQuery == term ? results.filter { store.security($0.symbol) == nil } : [] }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                HStack(spacing: Space.s8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
                    TextField("Company or ticker", text: $query)
                        .textFieldStyle(.plain).appCapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityLabel("Search company or ticker")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.muted) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.inputField()
                if !term.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(local) { item in MarketRow(item: item, market: store.market) }
                        ForEach(remote) { result in
                            Button { add(result.symbol) } label: {
                                HStack(spacing: Space.s12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(result.symbol).font(theme.body.weight(.semibold)).holdToExplainSymbol(result.symbol)
                                        Text("\(result.name) · \(result.kind.rawValue)").font(theme.meta).foregroundStyle(theme.muted).lineLimit(2)
                                    }
                                    Spacer()
                                    if adding == result.symbol { ProgressView() }
                                    else { Image(systemName: "plus").font(theme.meta).foregroundStyle(theme.muted) }
                                }.foregroundStyle(theme.ink).frame(minHeight: 58).padding(.vertical, Space.s12).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(adding != nil)
                            Rule()
                        }
                    }
                    if searching { ProgressView().frame(maxWidth: .infinity) }
                    else if local.isEmpty && remote.isEmpty {
                        Text(failed ? "Search is unavailable. Try again in a moment." : "No matches for “\(term)”.").font(theme.label).foregroundStyle(theme.muted)
                        if failed { Button("Try again") { Task { await search() } }.font(theme.label) }
                    }
                }
            }
        }
        .navigationTitle("").appInlineTitle()
        .task(id: term) { await search() }
    }

    private func search() async {
        let current = term
        failed = false
        guard !current.isEmpty else { results = []; resultQuery = ""; searching = false; return }
        searching = true
        defer { if current == term { searching = false } }
        try? await Task.sleep(for: .milliseconds(350)) // debounce typing; .task(id:) cancels stale searches
        guard !Task.isCancelled else { return }
        let found = await Feeds.yahooSearch(current)
        guard !Task.isCancelled, current == term else { return }
        results = found ?? []
        resultQuery = current
        failed = found == nil
    }

    private func add(_ symbol: String) {
        adding = symbol
        Task {
            if await store.addSecurity(symbol), let item = store.security(symbol) { store.openStock(item) }
            adding = nil
        }
    }
}
