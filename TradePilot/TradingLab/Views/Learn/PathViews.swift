import SwiftUI

/// The top of the Learn tab: the learning path, practice tools and labs.
struct LearnHubSections: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s24) {
            continueCard
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("Your learning path").font(theme.section)
                ForEach(Array(store.units.enumerated()), id: \.element.id) { index, unit in
                    NavigationLink { UnitView(store: store, unit: unit, number: index + 1) } label: { UnitRow(store: store, unit: unit, number: index + 1) }
                        .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: Space.s12) {
                Text("Practice and explore").font(theme.section)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.s12) {
                    tile("Chart drills", "chart.bar.xaxis", detail: store.dueDrills.isEmpty ? "All caught up" : "\(store.dueDrills.count) ready") { DrillsView(store: store) }
                    tile("Ask the tutor", "bubble.left.and.text.bubble.right", detail: "Questions, any time") { TutorView(store: store) }
                    tile("Market brief", "newspaper", detail: "What moved today") { MarketBriefView(store: store, market: store.market) }
                    tile("Famous market days", "clock.arrow.circlepath", detail: "\(Curriculum.events.count) replays") { EventListView(store: store) }
                    tile("Position-size lab", "dice", detail: "Why size matters") { SizingLabView(store: store) }
                    tile("Investing vs trading", "leaf", detail: "Real SPY history") { InvestingView(store: store) }
                }
            }
            NavigationLink { WeeklyReportView(store: store) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This week's report card").font(theme.label)
                        Text(store.weeklyReport.fix).font(theme.meta).foregroundStyle(theme.muted).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(theme.muted)
                }
                .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
            }.buttonStyle(.plain)
            NavigationLink { GlossaryView() } label: {
                Label("Glossary: \(Curriculum.glossary.count) terms in plain words", systemImage: "character.book.closed").font(theme.label)
            }
        }
    }

    @ViewBuilder private var continueCard: some View {
        let progress = store.pathProgress
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack {
                Eyebrow(text: "Learning path · \(progress.done) of \(progress.total) lessons")
                Spacer()
            }
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).tint(theme.accent)
            if let next = store.nextPathLesson {
                NavigationLink { PathLessonView(store: store, lesson: next) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.learning.progress[next.id] == nil ? "Up next" : "Continue").font(theme.meta).foregroundStyle(theme.muted)
                            Text(next.title).font(theme.section)
                            Text("\(next.minutes) min\(next.task != nil ? " · includes a practice task" : "")").font(theme.meta).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(theme.accent)
                    }
                }.buttonStyle(.plain)
            } else {
                Text("You've finished every lesson. Keep practicing with drills and replays.").font(theme.label)
            }
        }
        .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
    }

    private func tile<D: View>(_ title: String, _ icon: String, detail: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(theme.accent)
                Text(title).font(theme.label).foregroundStyle(theme.ink).multilineTextAlignment(.leading)
                Text(detail).font(theme.meta).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(Space.s12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        }.buttonStyle(.plain)
    }
}

private struct UnitRow: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    let unit: PathUnit
    let number: Int
    var body: some View {
        let done = unit.lessons.filter { store.learning.isComplete($0.id) }.count
        HStack(spacing: Space.s12) {
            ZStack {
                Circle().stroke(theme.line, lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(1, unit.lessons.count))).stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(number)").font(theme.label)
            }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(unit.title).font(theme.label)
                Text(unit.summary).font(theme.meta).foregroundStyle(theme.muted).lineLimit(2)
            }
            Spacer()
            Text("\(done)/\(unit.lessons.count)").font(theme.meta.monospacedDigit()).foregroundStyle(theme.muted)
        }
        .padding(.vertical, 6).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct UnitView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    let unit: PathUnit
    let number: Int
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Eyebrow(text: "Unit \(number)")
                Text(unit.title).font(theme.page)
                Text(unit.summary).foregroundStyle(theme.muted)
                Rule()
                ForEach(unit.lessons) { lesson in
                    NavigationLink { PathLessonView(store: store, lesson: lesson) } label: {
                        HStack(spacing: Space.s12) {
                            Image(systemName: store.learning.isComplete(lesson.id) ? "checkmark.circle.fill" : store.learning.progress[lesson.id] != nil ? "circle.lefthalf.filled" : "circle")
                                .foregroundStyle(store.learning.isComplete(lesson.id) ? theme.accent : theme.muted).font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(lesson.title).font(theme.label)
                                HStack(spacing: 6) {
                                    Text("\(lesson.minutes) min")
                                    if lesson.task != nil { Text("· practice task") }
                                    if !lesson.unlocks.isEmpty { Text("· unlocks \(lesson.unlocks.map(\.title).joined(separator: ", ").lowercased())") }
                                }.font(theme.meta).foregroundStyle(theme.muted).lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.vertical, Space.s8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Rule()
                }
            }
        }
        .learningTheme()
        .navigationTitle(unit.title).appInlineTitle()
    }
}

/// A lesson: short pages, then a quiz, then (sometimes) a task in the practice account.
struct PathLessonView: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LabStore
    let lesson: PathLesson
    @State private var page = 0
    @State private var answers: [Int: Int] = [:]
    @State private var stage: Stage = .reading

    enum Stage { case reading, quiz, task }

    private var progress: LessonProgress? { store.learning.progress[lesson.id] }
    private var quizCorrect: Bool { lesson.quiz.indices.allSatisfy { answers[$0] == lesson.quiz[$0].correct } }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s24) {
                VStack(alignment: .leading, spacing: 6) {
                    if let unit = Curriculum.content.unit(of: lesson.id) { Eyebrow(text: unit.title) }
                    Text(lesson.title).font(theme.page)
                    if store.learning.isComplete(lesson.id) {
                        Label("Completed", systemImage: "checkmark.seal.fill").font(theme.meta).foregroundStyle(theme.accent)
                    }
                }
                switch stage {
                case .reading: reading
                case .quiz: quiz
                case .task: taskView
                }
            }
            .animation(.easeInOut(duration: 0.25), value: page)
            .animation(.easeInOut(duration: 0.25), value: stage)
        }
        .learningTheme()
        .navigationTitle("Lesson").appInlineTitle()
        .onAppear {
            store.startLesson(lesson.id)
            if progress?.quizPassed == true { stage = lesson.task != nil ? .task : .reading }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            if page == 0, let graphic = lesson.graphic {
                ConceptGraphic(kind: graphic).frame(height: 160)
                    .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
            }
            Text(lesson.pages[page]).font(theme.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                .id(page).transition(.opacity)
            if page == lesson.pages.count - 1 && !lesson.terms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Words from this lesson")
                    FlowTerms(terms: lesson.terms)
                }
            }
            HStack(spacing: 6) {
                ForEach(lesson.pages.indices, id: \.self) { i in
                    Capsule().fill(i == page ? theme.accent : theme.line).frame(width: i == page ? 18 : 6, height: 6)
                }
            }.accessibilityHidden(true)
            HStack(spacing: Space.s12) {
                if page > 0 { ActionButton(title: "Back", secondary: true) { page -= 1 } }
                ActionButton(title: page < lesson.pages.count - 1 ? "Next" : "Check your understanding") {
                    if page < lesson.pages.count - 1 { page += 1 } else { stage = .quiz }
                }
            }
        }
    }

    private var quiz: some View {
        VStack(alignment: .leading, spacing: Space.s24) {
            ForEach(lesson.quiz.indices, id: \.self) { index in
                let q = lesson.quiz[index]
                VStack(alignment: .leading, spacing: Space.s12) {
                    Text(q.question).font(theme.section)
                    ForEach(q.options.indices, id: \.self) { option in
                        let chosen = answers[index] == option
                        let answered = answers[index] != nil
                        Button { if !answered || answers[index] != q.correct { answers[index] = option } } label: {
                            HStack {
                                Text(q.options[option]).multilineTextAlignment(.leading)
                                Spacer()
                                if chosen { Image(systemName: option == q.correct ? "checkmark.circle.fill" : "xmark.circle.fill") }
                            }
                            .font(theme.label).padding(Space.s12)
                            .foregroundStyle(chosen ? (option == q.correct ? theme.accent : theme.loss) : theme.ink)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                            .overlay(RoundedRectangle(cornerRadius: Space.smallRadius).stroke(chosen ? (option == q.correct ? theme.accent : theme.loss) : theme.line))
                        }.buttonStyle(.plain)
                    }
                    if let picked = answers[index] {
                        Text(picked == q.correct ? q.explanation : "Not quite. Try another answer.")
                            .font(theme.meta).foregroundStyle(picked == q.correct ? theme.ink : theme.muted)
                            .transition(.opacity)
                    }
                }
            }
            HStack(spacing: Space.s12) {
                ActionButton(title: "Reread", secondary: true) { page = 0; stage = .reading }
                ActionButton(title: lesson.task == nil ? "Finish lesson" : "Next: practice task", disabled: !quizCorrect) {
                    store.passQuiz(lesson.id)
                    if lesson.task == nil { dismiss() } else { stage = .task }
                }
            }
        }
    }

    @ViewBuilder private var taskView: some View {
        if let task = lesson.task {
            let done = store.taskDone(lesson)
            VStack(alignment: .leading, spacing: Space.s16) {
                Eyebrow(text: "Practice task")
                HStack(alignment: .top, spacing: Space.s12) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 26))
                        .foregroundStyle(done ? theme.accent : theme.muted)
                    Text(task.instruction).font(theme.section)
                }
                Text(done ? "Done! This lesson is complete." : "Do this in your practice account. It's checked automatically, using only what you do after starting this lesson.")
                    .font(theme.meta).foregroundStyle(theme.muted)
                if !done { TaskShortcut(store: store, kind: task.kind) }
                if !lesson.unlocks.isEmpty {
                    Text("Finishing this lesson unlocks: \(lesson.unlocks.map(\.title).joined(separator: ", ")).").font(theme.meta).foregroundStyle(theme.muted)
                }
            }
            .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
            .onAppear { store.refreshLessonTasks() }
        }
    }
}

/// Jumps to wherever the task can be done.
struct TaskShortcut: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    let kind: PathTask.Kind
    var body: some View {
        switch kind {
        case .marketOrder, .limitOrder, .stopLoss, .bracket, .sizeByRisk, .shortSell, .chartOpen, .indicator, .drawing:
            ActionButton(title: "Open the chart") { store.openChart(store.chartSymbol) }
        case .scanner: ActionButton(title: "Open the scanner") { store.tab = .scan }
        case .closeTrade: ActionButton(title: "Go to your positions") { store.tab = .home }
        case .reflection: NavigationLink { JournalAnalyticsView(store: store) } label: { linkLabel("Open the journal") }
        case .alert: NavigationLink { AlertsView(store: store) } label: { linkLabel("Set an alert") }
        case .replay: NavigationLink { ReplayHomeView(store: store) } label: { linkLabel("Start a bar replay") }
        case .drill: NavigationLink { DrillsView(store: store) } label: { linkLabel("Try a chart drill") }
        case .sizingLab: NavigationLink { SizingLabView(store: store) } label: { linkLabel("Open the position-size lab") }
        case .investingCalc: NavigationLink { InvestingView(store: store) } label: { linkLabel("Open the investing calculator") }
        }
    }
    private func linkLabel(_ text: String) -> some View {
        Text(text).font(theme.label).frame(maxWidth: .infinity, minHeight: 50).foregroundStyle(.white)
            .background(theme.buttonFill, in: RoundedRectangle(cornerRadius: Space.smallRadius))
    }
}

/// Glossary chips that wrap onto new lines.
struct FlowTerms: View {
    @Environment(\.theme) private var theme
    let terms: [String]
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(terms, id: \.self) { term in
                TermChip(term: term)
            }
        }
    }
}

private struct TermChip: View {
    @Environment(\.theme) private var theme
    let term: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Text(term).font(theme.meta).padding(.horizontal, 10).padding(.vertical, 5)
                .background(theme.surface, in: Capsule()).overlay(Capsule().stroke(theme.line))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { if let entry = Curriculum.term(term) { GlossarySheet(entry: entry).environment(\.theme, theme) } }
    }
}

/// Minimal wrapping layout for chips.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
