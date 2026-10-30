import SwiftUI
#if canImport(SafariServices) && os(iOS)
import SafariServices
#endif

struct NewsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @ObservedObject var news: NewsStore
    @State private var selectedSymbol: String?

    private var positionSymbols: [String] { store.heldSymbols }
    private var marketSymbols: [String] { store.allSecurities.map(\.symbol).filter { !positionSymbols.contains($0) }.sorted() }
    private var requested: [String] { selectedSymbol.map { [$0] } ?? Array(Set(store.data.watched + store.heldSymbols)) }

    var body: some View {
        let feed = news.feed(requested)
        let today = feed.articles.filter { Calendar.current.isDateInToday($0.date) }
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: Space.s8) {
                    Eyebrow(text: "The daily edition")
                    Text("News").font(.custom("Copperplate", size: 32, relativeTo: .largeTitle)).tracking(0.5)
                    Text("Published stories related to your markets and positions.")
                        .font(.custom("Charter", size: 17, relativeTo: .body)).foregroundStyle(theme.muted)
                }
                Menu {
                    Button("All relevant") { selectedSymbol = nil }
                    if !positionSymbols.isEmpty {
                        Section("Your positions") { ForEach(positionSymbols, id: \.self) { symbol in Button(symbol) { selectedSymbol = symbol } } }
                    }
                    Section("Markets") { ForEach(marketSymbols, id: \.self) { symbol in Button(symbol) { selectedSymbol = symbol } } }
                } label: {
                    HStack(spacing: Space.s8) {
                        Text(selectedSymbol ?? "All relevant")
                        Image(systemName: "chevron.down").font(theme.meta)
                    }
                    .font(theme.label).foregroundStyle(theme.accent)
                    .padding(.horizontal, Space.s16).padding(.vertical, Space.s8)
                    .background(theme.surface, in: Capsule()).overlay(Capsule().stroke(theme.line))
                }
                Rule()
                VStack(alignment: .leading, spacing: Space.s8) {
                    Eyebrow(text: "Today's recap")
                    if today.isEmpty {
                        Text(feed.loading ? "Finding today's stories…" : "No stories published today were found for this selection.")
                            .font(.custom("Charter", size: 18, relativeTo: .body))
                    } else {
                        Text("\(today.count) relevant \(today.count == 1 ? "story" : "stories") today. Leading headlines: \(today.prefix(2).map(\.cleanTitle).joined(separator: "; ")).")
                            .font(.custom("Charter", size: 18, relativeTo: .body)).lineSpacing(4)
                    }
                    Text("A headline recap, with links to the original articles.").font(theme.meta).foregroundStyle(theme.muted)
                }
                Rule()
                HStack(alignment: .firstTextBaseline) {
                    Text("Latest stories").font(.custom("Copperplate", size: 18, relativeTo: .headline))
                    Spacer(minLength: Space.s8)
                    NavigationLink("Saved research") { ResearchLibraryView(store: store) }.font(theme.meta).foregroundStyle(theme.accent)
                    if feed.loading { ProgressView() }
                }
                Text(feed.status).font(theme.meta).foregroundStyle(theme.muted)
                if feed.articles.isEmpty && !feed.loading {
                    ActionButton(title: "Try again", secondary: true) { Task { await news.load(requested, force: true) } }
                }
                ForEach(Array(feed.articles.enumerated()), id: \.element.id) { index, article in
                    NewsArticleRow(article: article, featured: index == 0, focusSymbol: selectedSymbol)
                }
            }
        }
        .task(id: NewsStore.key(requested)) { await news.load(requested) }
        .refreshable { await news.load(requested, force: true) }
        .appHideRootBar()
    }
}

struct ArticleImage: View {
    @Environment(\.theme) private var theme
    let url: URL
    let featured: Bool
    var body: some View {
        Rectangle().fill(theme.line.opacity(0.35))
            .frame(height: featured ? 180 : 82)
            .frame(maxWidth: featured ? .infinity : 104)
            .overlay {
                GeometryReader { geometry in
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Space.smallRadius))
            .accessibilityHidden(true)
    }
}

struct NewsArticleRow: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: LabStore
    let article: NewsArticle
    var featured = false
    var focusSymbol: String? = nil
    var body: some View {
        NavigationLink { ArticleView(article: article, focusSymbol: focusSymbol) } label: {
            VStack(alignment: .leading, spacing: Space.s12) {
                if featured, let imageURL = article.imageURL { ArticleImage(url: imageURL, featured: true) }
                HStack(alignment: .top, spacing: Space.s12) {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text(article.cleanTitle)
                            .font(.custom("Charter", size: featured ? 23 : 18, relativeTo: .title3))
                            .tracking(-0.2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true).foregroundStyle(theme.ink)
                        Text("\(article.source.uppercased())  ·  \(article.ageLabel())").font(theme.meta).tracking(0.4).foregroundStyle(theme.muted)
                    }
                    Spacer(minLength: 0)
                    if !featured, let imageURL = article.thumbnailURL ?? article.imageURL { ArticleImage(url: imageURL, featured: false) }
                }
                Rule()
            }
        }.buttonStyle(.plain)
        .contextMenu {
            Button(store.isArticleSaved(article.url) ? "Remove saved article" : "Save article") { store.toggleArticle(article) }
            ShareLink("Share article", item: article.url)
        }
    }
}

/// Headline, publisher summary and a link out. The publisher's article body is never copied into the app.
struct ArticleView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: LabStore
    let article: NewsArticle
    var focusSymbol: String? = nil
    @StateObject private var ai = AIImpactModel()
    @State private var showingNotes = false
    @State private var showingPublisher = false

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text(article.source.uppercased()).font(theme.meta).tracking(0.4).foregroundStyle(theme.muted)
                Text(article.cleanTitle).font(.custom("Charter", size: 31, relativeTo: .largeTitle)).tracking(-0.4)
                Text("\(article.date.formatted(date: .abbreviated, time: .shortened)) · \(article.ageLabel())").font(theme.meta).foregroundStyle(theme.muted)
                if let image = article.imageURL ?? article.thumbnailURL { ArticleImage(url: image, featured: true) }
                if let summary = article.summary {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Eyebrow(text: "Publisher summary")
                        Text(summary).font(.custom("Charter", size: 18, relativeTo: .body)).lineSpacing(5).textSelection(.enabled)
                    }
                }
                ActionButton(title: "Read at \(article.source)") { openPublisher() }
                Text("Opens the publisher's page. Trading Lab shows headlines and summaries only.").font(theme.meta).foregroundStyle(theme.muted)
                Rule()
                if AIImpactModel.hasKey {
                    HStack {
                        Text("What could this mean?").font(theme.section)
                        Spacer()
                        Button(ai.result == nil ? "Explain" : "Explain again") {
                            Task { await ai.analyze(article: article, symbol: focusSymbol ?? article.symbols.first) }
                        }.font(theme.label).foregroundStyle(theme.accent).disabled(ai.loading)
                    }
                    Text(article.summary == nil ? "Uses the headline only; this feed has no summary." : "Uses the headline and publisher summary.")
                        .font(theme.meta).foregroundStyle(theme.muted)
                    if ai.loading { ProgressView("Reading the headline…") }
                    if let result = ai.result { AIImpactPanel(result: result) }
                    if let error = ai.error { Text(error).font(theme.meta).foregroundStyle(theme.loss) }
                } else {
                    Text("Add a Gemini key in Profile → Settings to get a plain-language explanation of a headline.")
                        .font(theme.meta).foregroundStyle(theme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(article.source).appInlineTitle()
        .toolbar {
            ToolbarItemGroup {
                Button(store.isArticleSaved(article.url) ? "Saved" : "Save") { store.toggleArticle(article) }
                Button("Notes") { showingNotes = true }
                ShareLink(item: article.url)
            }
        }
        .sheet(isPresented: $showingNotes) {
            ResearchNoteEditor(store: store, article: article, symbol: focusSymbol ?? article.symbols.first ?? "").environment(\.theme, theme)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingPublisher) { SafariView(url: article.url).ignoresSafeArea() }
        #endif
    }

    private func openPublisher() {
        #if os(iOS)
        showingPublisher = true
        #else
        openURL(article.url)
        #endif
    }
}

#if os(iOS)
/// The publisher's own page (with Safari's Reader button), not a scraped copy.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

struct AIImpactPanel: View {
    @Environment(\.theme) private var theme
    let result: AIImpact
    private var color: Color {
        switch result.direction { case .up: return theme.green; case .down: return theme.loss; case .mixed: return theme.warning }
    }
    private var arrow: String {
        switch result.direction { case .up: return "arrow.up.right"; case .down: return "arrow.down.right"; case .mixed: return "arrow.left.and.right" }
    }
    private var headline: String {
        switch result.direction { case .up: return "Possible upside"; case .down: return "Possible downside"; case .mixed: return "Impact is mixed" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack(alignment: .top, spacing: Space.s12) {
                Image(systemName: arrow).font(.system(size: 22, weight: .medium)).foregroundStyle(color).frame(width: 28)
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text(headline).font(theme.section).foregroundStyle(color)
                    Text(result.impact).font(theme.body)
                }
            }
            Rule()
            Text("In brief").font(theme.label).foregroundStyle(theme.muted)
            Text(result.summary).font(.custom("Charter", size: 17, relativeTo: .body))
            Text("Watch next").font(theme.label).foregroundStyle(theme.muted)
            Text(result.watch).font(theme.body)
            if !result.questions.isEmpty {
                Text("Questions").font(theme.label).foregroundStyle(theme.muted)
                ForEach(result.questions, id: \.self) { question in Text("• \(question)").font(theme.body) }
            }
            Text("AI interpretation of a headline · check the source and current market data").font(theme.meta).foregroundStyle(theme.muted)
        }
        .padding(Space.s16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        .overlay(RoundedRectangle(cornerRadius: Space.radius).stroke(theme.line))
    }
}
