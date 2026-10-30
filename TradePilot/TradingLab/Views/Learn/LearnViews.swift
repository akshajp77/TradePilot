import SwiftUI
import Charts

struct LearnPracticeView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    @State private var section = "Learn"
    private let sections = ["Learn", "Practice", "Review"]

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                Text("Learn & practice").font(theme.page).tracking(-0.6)
                HStack(spacing: Space.s24) {
                    ForEach(sections, id: \.self) { option in
                        Button { section = option } label: {
                            VStack(spacing: Space.s8) {
                                Text(option).font(theme.label).foregroundStyle(section == option ? theme.ink : theme.muted)
                                Rectangle().fill(section == option ? theme.accent : .clear).frame(height: 2)
                            }
                        }.buttonStyle(.plain).accessibilityAddTraits(section == option ? .isSelected : [])
                    }
                }
                Rule()
                if Curriculum.isMissing {
                    Text("Lessons.json is missing from the app bundle. Add the Resources folder to the app target.").foregroundStyle(theme.loss)
                }
                switch section {
                case "Learn": lessons
                case "Practice": PracticeSection(store: store, market: store.market)
                default: review
                }
            }
        }
        .learningTheme()
        .appHideRootBar()
    }

    private var lessons: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            if store.profile == nil { AboutYouCard(store: store) }
            LearnHubSections(store: store)
            Rule()
            Text("More short lessons").font(theme.section)
            BiteLessonPreviews(store: store)
            NavigationLink { GuidedPracticeView(store: store) } label: {
                Text("Your next steps →").font(theme.label).foregroundStyle(theme.accent)
            }
            DisclosureGroup("Practice challenges") { ChallengeSection(store: store) }.font(theme.label)
            Rule()
            ForEach(Curriculum.lessons) { lesson in
                NavigationLink { LessonView(store: store, lesson: lesson) } label: {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        HStack {
                            Eyebrow(text: lesson.path)
                            Spacer()
                            if store.data.completedChecks.contains(lesson.id) { Text("Completed").font(theme.meta).foregroundStyle(theme.accent) }
                        }
                        Text(lesson.title).font(theme.section).foregroundStyle(theme.ink)
                        Text("\(lesson.seconds) sec · question included").font(theme.meta).foregroundStyle(theme.muted)
                        Rule()
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("Review the decision, not just the result.").foregroundStyle(theme.muted)
            Text("\(store.data.completedChecks.count) of \(Curriculum.lessons.count) concept checks complete").font(theme.label)
            Rule()
            let pending = store.data.orders.filter { $0.status == .filled && $0.reflection.isEmpty }
            Text("Needs reflection").font(theme.section)
            if pending.isEmpty { Text("No filled orders need a reflection.").foregroundStyle(theme.muted) }
            ForEach(pending) { order in
                NavigationLink { OrderDetailView(store: store, id: order.id) } label: {
                    Text("\(order.side.rawValue) \(order.symbol) · What did you learn?").font(theme.label).foregroundStyle(theme.accent).padding(.vertical, Space.s8)
                }
                Rule()
            }
            NavigationLink("Open searchable journal →") { JournalView(store: store) }.font(theme.label).foregroundStyle(theme.accent)
            Text("Journal").font(theme.section)
            if store.data.orders.isEmpty { Text("Your plans and reflections will collect here.").foregroundStyle(theme.muted) }
            ForEach(store.data.orders) { order in
                NavigationLink { OrderDetailView(store: store, id: order.id) } label: {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        Text("\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol)").font(theme.label).foregroundStyle(theme.ink)
                        Text(order.reflection.isEmpty ? "Reflection not written" : order.reflection).font(theme.meta).foregroundStyle(theme.muted).lineLimit(2)
                    }.padding(.vertical, Space.s8)
                }.buttonStyle(.plain)
                Rule()
            }
        }
    }
}

private struct PracticeSection: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    @ObservedObject var market: MarketData
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("Practice account").font(theme.section)
            Text("\(store.portfolioValue.map(Format.money) ?? "Value pending") total · \(Format.money(store.cash)) cash").font(theme.label)
            Rule()
            Text("Positions").font(theme.section)
            if store.heldSymbols.isEmpty { Text("No positions yet. Open the Chart tab to place your first practice trade.").foregroundStyle(theme.muted) }
            ForEach(store.heldSymbols, id: \.self) { symbol in
                if let item = store.security(symbol) {
                    Button { store.openStock(item, order: store.heldSymbols) } label: {
                        HStack {
                            Text("\(symbol) · \(Format.shares(store.shares(symbol))) shares")
                            Spacer()
                            Text(store.positionValue(symbol).map(Format.money) ?? "Pending")
                        }.font(theme.label).foregroundStyle(theme.ink).padding(.vertical, Space.s8)
                    }.buttonStyle(.plain)
                    Rule()
                }
            }
            Text("Orders").font(theme.section)
            if store.data.orders.isEmpty { Text("Your practice orders will appear here.").foregroundStyle(theme.muted) }
            ForEach(store.data.orders) { order in
                NavigationLink { OrderDetailView(store: store, id: order.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.s4) {
                            Text("\(order.side.rawValue) \(Format.shares(order.shares)) \(order.symbol)").font(theme.label)
                            Text(order.submittedAt.formatted(date: .abbreviated, time: .shortened)).font(theme.meta).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        OrderStatusLabel(status: order.status)
                    }.foregroundStyle(theme.ink).padding(.vertical, Space.s8)
                }.buttonStyle(.plain)
                Rule()
            }
            NavigationLink { ReplayView() } label: { Text("Try a decision replay →").font(theme.label).foregroundStyle(theme.accent) }
        }
    }
}

struct OrderStatusLabel: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    let status: OrderStatus
    var body: some View {
        Text(status.rawValue).font(theme.meta)
            .foregroundStyle(status == .filled ? theme.accent : status == .canceled ? theme.muted : theme.warning)
    }
}

struct LessonView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    let lesson: Lesson
    @State private var selection: Int?
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                Eyebrow(text: lesson.path)
                Text(lesson.title).font(theme.page).tracking(-0.6)
                Text(lesson.hook).font(theme.section)
                Rule()
                Text(lesson.explanation).lineSpacing(5)
                VStack(alignment: .leading, spacing: Space.s8) {
                    Eyebrow(text: "For example")
                    Text(lesson.example)
                }
                Rule()
                Text("Check your thinking").font(theme.section)
                Text(lesson.question)
                ForEach(lesson.options.indices, id: \.self) { index in
                    Button {
                        selection = index
                        if index == lesson.correct { store.completeCheck(lesson.id) }
                    } label: {
                        HStack {
                            Text(lesson.options[index]).multilineTextAlignment(.leading)
                            Spacer()
                            if selection == index { Text(index == lesson.correct ? "Correct" : "Try again") }
                        }
                        .font(theme.label).foregroundStyle(theme.ink).padding(Space.s16)
                        .background(selection == index ? (index == lesson.correct ? theme.accent.opacity(0.12) : theme.loss.opacity(0.12)) : theme.surface,
                                    in: RoundedRectangle(cornerRadius: Space.smallRadius))
                        .overlay(RoundedRectangle(cornerRadius: Space.smallRadius).stroke(theme.line))
                    }.buttonStyle(.plain)
                }
                if selection != nil { Text(lesson.feedback).font(theme.label).foregroundStyle(theme.muted) }
                if let item = store.security(lesson.symbol) {
                    Button { store.openStock(item) } label: { Text("Explore \(item.symbol) →").font(theme.label).foregroundStyle(theme.accent) }
                }
            }
        }
        .learningTheme()
        .navigationTitle("Lesson").appInlineTitle()
    }
}

struct OrderDetailView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    let id: UUID
    @State private var reflection = ""
    var body: some View {
        Page {
            if let order = store.data.orders.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Text("\(order.side.rawValue) \(order.symbol)").font(theme.page)
                    HStack(spacing: Space.s8) {
                        OrderStatusLabel(status: order.status)
                        Text("· \(order.submittedAt.formatted(date: .abbreviated, time: .shortened))").font(theme.meta).foregroundStyle(theme.muted)
                    }
                    if let note = order.statusNote { Text(note).font(theme.meta).foregroundStyle(theme.muted) }
                    Rule()
                    ExplainRow("Shares", value: Format.shares(order.shares))
                    ExplainRow("Order type", value: order.type.rawValue)
                    if let fill = order.fillPrice { ExplainRow("Virtual fill", value: Format.money(fill)) }
                    if let filledAt = order.filledAt { ExplainRow("Filled", value: filledAt.formatted(date: .abbreviated, time: .shortened)) }
                    if let limit = order.limit { ExplainRow("Limit price", value: Format.money(limit)) }
                    if let stop = order.effectiveStop { ExplainRow(order.type == .trailingStop ? "Trailing stop" : "Stop price", value: Format.money(stop)) }
                    if order.role != .entry { ExplainRow("Role", value: order.role.rawValue) }
                    if order.status.isPending {
                        Button(order.status == .queued ? "Cancel queued order" : "Cancel open order", role: .destructive) { store.cancel(id) }
                    }
                    Rule()
                    Text("Your plan").font(theme.section)
                    Text(order.thesis.isEmpty ? "No thesis recorded." : order.thesis)
                    Text("Change my mind if: \(order.invalidation)")
                    Text("Horizon: \(order.horizon)")
                    Rule()
                    Text("Reflection").font(theme.section)
                    Text("What changed? Did you follow your plan?").foregroundStyle(theme.muted)
                    TextEditor(text: $reflection).frame(minHeight: 140).scrollContentBackground(.hidden)
                        .padding(Space.s8).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                        .overlay(RoundedRectangle(cornerRadius: Space.smallRadius).stroke(theme.line))
                    ActionButton(title: "Save reflection", disabled: reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        store.reflect(id, text: reflection.trimmingCharacters(in: .whitespacesAndNewlines))
                        store.showToast("Reflection saved.")
                    }
                }
            } else {
                Text("This order no longer exists.").foregroundStyle(theme.muted)
            }
        }
        .learningTheme()
        .navigationTitle("Order review").appInlineTitle()
        .onAppear { reflection = store.data.orders.first(where: { $0.id == id })?.reflection ?? "" }
    }
}

struct ReplayView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    private let scenario = Curriculum.replay
    @State private var revealed = Curriculum.replay.revealAt
    @State private var prediction: String?
    private struct Step: Identifiable { let id: Int; let price: Double }

    var body: some View {
        let shown = scenario.prices.prefix(revealed).enumerated().map { Step(id: $0.offset, price: $0.element) }
        let low = (scenario.prices.min() ?? 0) * 0.9, high = (scenario.prices.max() ?? 1) * 1.1
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                Eyebrow(text: scenario.note)
                Text("Decision replay").font(theme.page)
                Text("\(scenario.name) (\(scenario.symbol)) is fictional. See the first steps, make a decision, then reveal the rest.").foregroundStyle(theme.muted)
                Chart(shown) { step in
                    LineMark(x: .value("Step", step.id), y: .value("Sample price", step.price)).foregroundStyle(theme.accent)
                }.chartXScale(domain: 0...max(1, scenario.prices.count - 1)).chartYScale(domain: low...high).frame(height: 210)
                if prediction == nil {
                    ForEach(["Buy a small position", "Wait for evidence", "Avoid this trade"], id: \.self) { choice in
                        ActionButton(title: choice, secondary: true) { prediction = choice }
                    }
                } else {
                    Text("Your decision: \(prediction ?? "")").font(theme.label)
                    ActionButton(title: revealed == scenario.prices.count ? "Start again" : "Reveal next step") {
                        if revealed < scenario.prices.count { revealed += 1 } else { revealed = scenario.revealAt; prediction = nil }
                    }
                    if revealed == scenario.prices.count {
                        Text("Review your reason and position size. The result alone cannot judge the decision.").foregroundStyle(theme.muted)
                    }
                }
            }
        }
        .learningTheme()
        .navigationTitle("Replay").appInlineTitle()
    }
}

struct ChallengeSection: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    var body: some View {
        let challenges = store.challenges
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack {
                Text("Practice challenges").font(theme.section)
                Spacer()
                Text("\(challenges.filter(\.complete).count) / \(challenges.count)").font(theme.meta)
            }
            ForEach(challenges) { challenge in
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack {
                        Text(challenge.title).font(theme.label)
                        Spacer()
                        Text(challenge.complete ? "Complete" : "To try").font(theme.meta).foregroundStyle(challenge.complete ? theme.accent : theme.muted)
                    }
                    Text(challenge.detail).font(theme.meta).foregroundStyle(theme.muted)
                }
            }
        }
    }
}

struct GuidedPracticeView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                Eyebrow(text: "Practice")
                Text("A guided first session").font(theme.page)
                Picker("Learning goal", selection: Binding(get: { store.data.goal }, set: { goal in store.mutateActive { $0.goal = goal } })) {
                    ForEach(LabStore.goals, id: \.self) { Text($0) }
                }
                Text("Next: \(store.nextLearningTitle)").font(theme.label)
                Rule()
                Text("1. Understand the decision").font(theme.section)
                ForEach(Curriculum.lessons.filter { $0.title == store.nextLearningTitle }) { lesson in
                    FeatureLink(title: lesson.title, detail: "Read an example and answer one question") { LessonView(store: store, lesson: lesson) }
                }
                Text("2. Research one market").font(theme.section)
                Text("Read the business description, inspect the price source, and save a piece of evidence.").foregroundStyle(theme.muted)
                if let item = store.security("AAPL") {
                    Button("Explore Apple →") { store.openStock(item) }.font(theme.label).foregroundStyle(theme.accent)
                }
                Text("3. Make a small practice decision").font(theme.section)
                Text("Open a stock’s order ticket. Review the position-size preview, then write why you would trade and what would change your mind.").foregroundStyle(theme.muted)
                Text("4. Review your reasoning").font(theme.section)
                FeatureLink(title: "Open your journal") { JournalView(store: store) }
                ChallengeSection(store: store)
                FeatureLink(title: "Explain a market term") { GlossaryView() }
            }
        }
        .learningTheme()
        .navigationTitle("Guided practice").appInlineTitle()
    }
}

struct GlossaryView: View {
    @Environment(\.theme) private var theme
    @State private var query = ""
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Market terms").font(theme.page)
                TextField("Find a term", text: $query).inputField()
                ForEach(Curriculum.glossary.filter { entry in
                    query.isEmpty || ([entry.term, entry.explanation] + (entry.aliases ?? [])).joined(separator: " ").localizedCaseInsensitiveContains(query)
                }.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }) { entry in
                    DisclosureGroup {
                        if let graphic = entry.graphic { ConceptGraphic(kind: graphic).frame(height: 130).padding(.top, Space.s8) }
                        Text(entry.explanation).padding(.vertical, Space.s8)
                        Text(entry.example).font(theme.label).foregroundStyle(theme.muted)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.term).font(theme.label)
                            if let aliases = entry.aliases, !aliases.isEmpty { Text("Also: " + aliases.prefix(3).joined(separator: ", ")).font(theme.meta).foregroundStyle(theme.muted) }
                        }
                    }
                    Rule()
                }
            }
        }.navigationTitle("Glossary").appInlineTitle()
    }
}
