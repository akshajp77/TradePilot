import Foundation

// MARK: - Learner profile (onboarding answers)

nonisolated enum Experience: String, Codable, CaseIterable, Sendable, Identifiable {
    case none = "I've never traded"
    case some = "I've bought a few stocks"
    case regular = "I trade sometimes"
    case experienced = "I day trade already"
    var id: String { rawValue }
    /// Beginners start with the basics and unlock advanced tools as they learn them.
    var startsUnlocked: Bool { self == .experienced || self == .regular }
}

nonisolated enum LearnerGoal: String, Codable, CaseIterable, Sendable, Identifiable {
    case basics = "Learn how the stock market works"
    case practice = "Practice before using real money"
    case investing = "Build long-term investing habits"
    case dayTrading = "Learn day trading"
    case strategies = "Test my own strategies"
    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .basics: return "book"
        case .practice: return "figure.walk"
        case .investing: return "leaf"
        case .dayTrading: return "bolt"
        case .strategies: return "flask"
        }
    }
}

nonisolated enum WeeklyTime: String, Codable, CaseIterable, Sendable, Identifiable {
    case little = "About 15 minutes"
    case some = "An hour or two"
    case lots = "Several hours"
    var id: String { rawValue }
}

nonisolated enum RiskComfort: String, Codable, CaseIterable, Sendable, Identifiable {
    case sell = "Sell everything so I stop losing"
    case wait = "Feel nervous, but wait and see"
    case check = "Check why it dropped before deciding"
    case buyMore = "Buy more because it's cheaper"
    var id: String { rawValue }
    /// Shown right after the answer; there is no wrong answer, only something to know about yourself.
    var insight: String {
        switch self {
        case .sell: return "Lots of people feel this way. Small position sizes and stop losses will help you stay calm, and the app will show you how."
        case .wait: return "Normal and healthy. A written plan before each trade makes waiting easier, because you'll know what you're waiting for."
        case .check: return "That's the habit good traders build: find out what changed, then decide. You're off to a strong start."
        case .buyMore: return "Sometimes that works, but a falling price can keep falling. You'll learn when \"cheaper\" is really a warning sign."
        }
    }
}

nonisolated struct LearnerProfile: Codable, Hashable, Sendable {
    var birthYear: Int?
    var experience: Experience = .none
    var goals: [LearnerGoal] = []
    var weeklyTime: WeeklyTime = .some
    var riskComfort: RiskComfort?
    var completedAt = Date()

    /// Self-reported, so approximate: within a year of the true age.
    func age(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        birthYear.map { calendar.component(.year, from: now) - $0 }
    }
    func isAdult(now: Date = Date()) -> Bool { (age(now: now) ?? 0) >= 18 }
}

// MARK: - Learning path

/// Tools that unlock once the lesson that teaches them is finished.
nonisolated enum LabFeature: String, Codable, CaseIterable, Sendable {
    case shorting, margin, advancedOrders, extendedHours

    var title: String {
        switch self {
        case .shorting: return "Short selling"
        case .margin: return "Margin (borrowed money)"
        case .advancedOrders: return "Stop-limit and trailing stop orders"
        case .extendedHours: return "Trading before and after regular hours"
        }
    }
}

nonisolated struct QuizQuestion: Codable, Hashable, Sendable {
    let question: String
    let options: [String]
    let correct: Int
    let explanation: String
}

/// Something the learner does in the practice account; the app checks it.
nonisolated struct PathTask: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case marketOrder, limitOrder, stopLoss, bracket, sizeByRisk, closeTrade, reflection
        case alert, indicator, drawing, scanner, replay, drill, sizingLab, investingCalc, shortSell, chartOpen
    }
    let kind: Kind
    let instruction: String
}

nonisolated struct PathLesson: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let minutes: Int
    /// Short screens of plain-language text.
    let pages: [String]
    /// Glossary terms to link from this lesson.
    var terms: [String] = []
    let quiz: [QuizQuestion]
    var task: PathTask?
    var unlocks: [LabFeature] = []
    /// Concept drawing shown on the first page (see ConceptGraphic).
    var graphic: String?

    init(id: String, title: String, minutes: Int, pages: [String], terms: [String] = [], quiz: [QuizQuestion],
         task: PathTask? = nil, unlocks: [LabFeature] = [], graphic: String? = nil) {
        self.id = id; self.title = title; self.minutes = minutes; self.pages = pages; self.terms = terms
        self.quiz = quiz; self.task = task; self.unlocks = unlocks; self.graphic = graphic
    }
    private enum CodingKeys: String, CodingKey { case id, title, minutes, pages, terms, quiz, task, unlocks, graphic }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 3
        pages = try c.decode([String].self, forKey: .pages)
        terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        quiz = try c.decode([QuizQuestion].self, forKey: .quiz)
        task = try c.decodeIfPresent(PathTask.self, forKey: .task)
        unlocks = try c.decodeIfPresent([LabFeature].self, forKey: .unlocks) ?? []
        graphic = try c.decodeIfPresent(String.self, forKey: .graphic)
    }
}

nonisolated struct PathUnit: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let lessons: [PathLesson]
}

nonisolated struct LessonProgress: Codable, Hashable, Sendable {
    var startedAt = Date()
    var quizPassed = false
    var taskDone = false
    var completedAt: Date?
}

nonisolated struct DrillBox: Codable, Hashable, Sendable {
    /// Leitner box 0–4: higher boxes come back less often.
    var box = 0
    var nextDue: Date = .distantPast
    var attempts = 0
    var correct = 0
    static let intervals: [TimeInterval] = [0, 86_400, 3 * 86_400, 7 * 86_400, 21 * 86_400]

    mutating func record(correct right: Bool, now: Date = Date()) {
        attempts += 1
        if right { correct += 1; box = min(4, box + 1) } else { box = 0 }
        nextDue = now.addingTimeInterval(Self.intervals[box])
    }
    var accuracy: Double? { attempts > 0 ? Double(correct) / Double(attempts) : nil }
}

nonisolated struct EventReplayRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var eventID: String
    var choices: [String: String] = [:]
    /// Value of $1,000 following the learner's choices vs simply holding.
    var endingValue: Double
    var holdValue: Double
    var completedAt = Date()
}

/// Everything about the learner's progress; synced with the workspace.
nonisolated struct LearningState: Codable, Hashable, Sendable {
    var profile: LearnerProfile?
    var progress: [String: LessonProgress] = [:]
    /// Last time the learner did each kind of thing (for task checks).
    var actions: [String: Date] = [:]
    /// nil means everything is unlocked (existing users and experienced traders).
    var unlocked: [LabFeature]?
    var drills: [String: DrillBox] = [:]
    var eventReplays: [EventReplayRecord] = []
    var coolDownUntil: Date?
    /// When the learner accepted the real-money override (only possible for adults).
    var liveOverrideAt: Date?
    var lastWeeklyReport: Date?

    init() {}
    private enum CodingKeys: String, CodingKey { case profile, progress, actions, unlocked, drills, eventReplays, coolDownUntil, liveOverrideAt, lastWeeklyReport }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try? c.decodeIfPresent(LearnerProfile.self, forKey: .profile)
        progress = (try? c.decodeIfPresent([String: LessonProgress].self, forKey: .progress)) ?? [:]
        actions = (try? c.decodeIfPresent([String: Date].self, forKey: .actions)) ?? [:]
        unlocked = (try? c.decodeIfPresent([String].self, forKey: .unlocked))?.compactMap(LabFeature.init(rawValue:))
        drills = (try? c.decodeIfPresent([String: DrillBox].self, forKey: .drills)) ?? [:]
        eventReplays = (try? c.decodeIfPresent([EventReplayRecord].self, forKey: .eventReplays)) ?? []
        coolDownUntil = try? c.decodeIfPresent(Date.self, forKey: .coolDownUntil)
        liveOverrideAt = try? c.decodeIfPresent(Date.self, forKey: .liveOverrideAt)
        lastWeeklyReport = try? c.decodeIfPresent(Date.self, forKey: .lastWeeklyReport)
    }

    func isUnlocked(_ feature: LabFeature) -> Bool { unlocked.map { $0.contains(feature) } ?? true }
    func isComplete(_ lessonID: String) -> Bool { progress[lessonID]?.completedAt != nil }

    static func merge(_ mine: LearningState, _ theirs: LearningState) -> LearningState {
        var m = mine
        switch (mine.profile, theirs.profile) {
        case (nil, let t): m.profile = t
        case (let a?, let b?) where b.completedAt > a.completedAt: m.profile = b
        default: break
        }
        for (id, t) in theirs.progress {
            guard var p = m.progress[id] else { m.progress[id] = t; continue }
            p.startedAt = min(p.startedAt, t.startedAt)
            p.quizPassed = p.quizPassed || t.quizPassed
            p.taskDone = p.taskDone || t.taskDone
            p.completedAt = [p.completedAt, t.completedAt].compactMap { $0 }.min()
            m.progress[id] = p
        }
        m.actions = mine.actions.merging(theirs.actions) { max($0, $1) }
        if let a = mine.unlocked, let b = theirs.unlocked { m.unlocked = LabFeature.allCases.filter { a.contains($0) || b.contains($0) } } else { m.unlocked = nil }
        m.drills = mine.drills.merging(theirs.drills) { $0.attempts >= $1.attempts ? $0 : $1 }
        m.eventReplays = WorkspaceMerge.unionBy(mine.eventReplays, theirs.eventReplays, key: \.id).sorted { $0.completedAt > $1.completedAt }
        m.coolDownUntil = [mine.coolDownUntil, theirs.coolDownUntil].compactMap { $0 }.max()
        m.liveOverrideAt = [mine.liveOverrideAt, theirs.liveOverrideAt].compactMap { $0 }.min()
        m.lastWeeklyReport = [mine.lastWeeklyReport, theirs.lastWeeklyReport].compactMap { $0 }.max()
        return m
    }
}

// MARK: - Task checks

nonisolated enum PathTasks {
    /// Whether the learner has done the task since `since` in this practice account.
    static func isDone(_ task: PathTask, since: Date, account: AccountData, learning: LearningState,
                       notes: [String: TradeNote] = [:]) -> Bool {
        let orders = account.orders.filter { $0.submittedAt >= since }
        func acted(_ key: String) -> Bool { (learning.actions[key] ?? .distantPast) >= since }
        switch task.kind {
        case .marketOrder: return orders.contains { $0.type == .market && $0.role == .entry && $0.status != .canceled }
        case .limitOrder: return orders.contains { $0.type == .limit && $0.role == .entry }
        case .stopLoss: return orders.contains { $0.role == .stopLoss || ($0.type == .stop && $0.reduceOnly) }
        case .bracket:
            return orders.contains { entry in
                guard entry.role == .entry, let stop = entry.plannedStop, let target = entry.plannedTarget else { return false }
                let reference = entry.limit ?? entry.fillPrice ?? entry.reference ?? 0
                let risk = abs(reference - stop), reward = abs(target - reference)
                return risk > 0 && reward >= risk
            }
        case .sizeByRisk:
            return orders.contains { entry in
                guard entry.role == .entry, let stop = entry.plannedStop else { return false }
                let reference = entry.limit ?? entry.fillPrice ?? entry.reference ?? 0
                let risk = abs(reference - stop) * entry.shares
                return risk > 0 && risk <= account.initialBalance * Decimal(string: "0.02")!
            }
        case .closeTrade:
            let trips = TradeAnalytics.roundTrips(account, notes: notes)
            return trips.contains { !$0.isOpen && ($0.exitTime ?? .distantPast) >= since }
        case .reflection: return account.orders.contains { !$0.reflection.isEmpty && $0.updatedAt >= since }
        case .shortSell:
            let ledgerTrips = TradeAnalytics.roundTrips(account, notes: notes)
            return ledgerTrips.contains { !$0.isLong && $0.entryTime >= since }
        case .alert: return acted("alert")
        case .indicator: return acted("indicator")
        case .drawing: return acted("drawing")
        case .scanner: return acted("scanner")
        case .replay: return acted("replay")
        case .drill: return acted("drill")
        case .sizingLab: return acted("sizingLab")
        case .investingCalc: return acted("investingCalc")
        case .chartOpen: return acted("chart")
        }
    }
}
