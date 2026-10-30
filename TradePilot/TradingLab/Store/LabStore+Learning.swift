import Foundation

/// Learning path, coaching, readiness and onboarding on top of the practice account.
extension LabStore {
    var learning: LearningState { workspace.features.learning }
    var profile: LearnerProfile? { learning.profile }
    var units: [PathUnit] { Curriculum.units }

    func mutateLearning(_ change: (inout LearningState) -> Void) {
        var updated = workspace
        change(&updated.features.learning)
        if updated != workspace { replaceWorkspace(updated) }
    }

    func isUnlocked(_ feature: LabFeature) -> Bool { learning.isUnlocked(feature) }

    /// Plain-language reason an order needs a lesson first, or nil.
    func lockedReason(for request: OrderRequest) -> String? {
        let held = shares(request.symbol)
        let opensShort = request.side == .sell && request.role == .entry && !request.reduceOnly && request.shares > max(0, held)
        func reason(_ feature: LabFeature) -> String {
            let lesson = Curriculum.content.lesson(unlocking: feature)?.title ?? "its lesson"
            return "\(feature.title) unlocks after the lesson \"\(lesson)\" in Learn. Finish it first so you know the risks."
        }
        if opensShort && !isUnlocked(.shorting) {
            return held > 0 ? "You only own \(Format.shares(held)) shares. Selling more than you own is short selling. " + reason(.shorting) : reason(.shorting)
        }
        if (request.type == .stopLimit || request.type == .trailingStop) && !isUnlocked(.advancedOrders) { return reason(.advancedOrders) }
        if request.extendedHours && !isUnlocked(.extendedHours) { return reason(.extendedHours) }
        return nil
    }

    // MARK: Actions and lesson tasks

    func recordAction(_ key: String, at date: Date = Date()) {
        mutateLearning { $0.actions[key] = date }
        refreshLessonTasks()
    }

    func startLesson(_ id: String) {
        guard learning.progress[id] == nil else { return }
        mutateLearning { $0.progress[id] = LessonProgress() }
    }

    func passQuiz(_ id: String) {
        mutateLearning { $0.progress[id, default: LessonProgress()].quizPassed = true }
        refreshLessonTasks()
    }

    func taskDone(_ lesson: PathLesson) -> Bool {
        guard let task = lesson.task else { return true }
        if learning.progress[lesson.id]?.taskDone == true { return true }
        let since = learning.progress[lesson.id]?.startedAt ?? Date()
        return PathTasks.isDone(task, since: since, account: data, learning: learning, notes: features.tradeNotes)
    }

    /// Marks finished tasks and completes lessons whose quiz and task are both done.
    func refreshLessonTasks() {
        var completed: [PathLesson] = []
        var updated = learning
        for lesson in Curriculum.content.pathLessons {
            guard var progress = updated.progress[lesson.id], progress.completedAt == nil else { continue }
            if !progress.taskDone, let task = lesson.task,
               PathTasks.isDone(task, since: progress.startedAt, account: data, learning: updated, notes: features.tradeNotes) {
                progress.taskDone = true
            }
            if lesson.task == nil { progress.taskDone = true }
            if progress.quizPassed && progress.taskDone {
                progress.completedAt = Date()
                completed.append(lesson)
            }
            updated.progress[lesson.id] = progress
        }
        guard updated != learning else { return }
        mutateLearning { $0 = updated }
        for lesson in completed { finished(lesson) }
    }

    private func finished(_ lesson: PathLesson) {
        var unlocked: [String] = []
        for feature in lesson.unlocks where !isUnlocked(feature) {
            mutateLearning { state in state.unlocked = (state.unlocked ?? []) + [feature] }
            switch feature {
            case .margin: updateSettings { $0.accountType = .margin }
            case .shorting: updateSettings { $0.shortingEnabled = true }
            default: break
            }
            unlocked.append(feature.title)
        }
        if unlocked.isEmpty { showToast("Lesson complete: \(lesson.title)") }
        else { notice = "Lesson complete: \(lesson.title).\n\nUnlocked in your practice account: \(unlocked.joined(separator: ", "))." }
    }

    var nextPathLesson: PathLesson? { Curriculum.content.pathLessons.first { !learning.isComplete($0.id) } }
    var pathProgress: (done: Int, total: Int) {
        let all = Curriculum.content.pathLessons
        return (all.filter { learning.isComplete($0.id) }.count, all.count)
    }

    // MARK: Coaching

    func coachNotes(for request: OrderRequest, entry: Decimal?) -> [CoachNote] {
        let now = Date()
        let daily = market.candles(request.symbol, .d1).map(\.close)
        let sma = daily.count >= 50 ? daily.suffix(50).reduce(0, +) / 50 : nil
        let quote = market.quote(request.symbol)
        let today = todaysTrips
        let inputs = PreTradeInputs(
            request: request, entry: entry, equity: portfolioValue, currentShares: shares(request.symbol),
            bid: quote.flatMap { $0.bid }, ask: quote.flatMap { $0.ask },
            averageVolume: market.statistics[request.symbol]?.volume.flatMap { $0 > 0 ? $0 : nil },
            nextEarnings: market.nextEarnings(request.symbol)?.date,
            sma50: sma, lastClose: daily.last,
            lastLossAt: TiltGuard.lastLoss(today), entriesLast30Minutes: TiltGuard.entries(data, within: 1800, now: now),
            consecutiveLosses: TiltGuard.consecutiveLosses(today), now: now)
        return PreTradeCheck.notes(inputs)
    }

    var isCoolingDown: Bool { (learning.coolDownUntil ?? .distantPast) > Date() }

    func startCoolDown(minutes: Int = 15) {
        mutateLearning { $0.coolDownUntil = Date().addingTimeInterval(TimeInterval(minutes * 60)) }
        tiltPrompt = false
    }

    func endCoolDown() { mutateLearning { $0.coolDownUntil = nil } }

    /// After fills: lesson tasks, and a break suggestion when a third straight loss closes.
    func noteTradeActivity() {
        refreshLessonTasks()
        let today = todaysTrips
        if TiltGuard.consecutiveLosses(today) == 3, !isCoolingDown,
           let lastLoss = TiltGuard.lastLoss(today), Date().timeIntervalSince(lastLoss) < 120 {
            tiltPrompt = true
        }
    }

    /// The most recently closed trade and its process grade.
    var lastReview: (trip: RoundTrip, review: TradeReview)? {
        guard let trip = roundTrips.filter({ !$0.isOpen }).max(by: { ($0.exitTime ?? $0.entryTime) < ($1.exitTime ?? $1.entryTime) }) else { return nil }
        return (trip, review(trip))
    }

    func review(_ trip: RoundTrip) -> TradeReview {
        let entry = data.orders.first { $0.id == trip.id }
        return TradeReview.review(trip, entry: entry, note: features.tradeNotes[trip.id.uuidString], equity: portfolioValue ?? data.initialBalance)
    }

    var weeklyReport: WeeklyReport {
        WeeklyReport.build(trips: roundTrips, account: data, notes: features.tradeNotes,
                           equity: portfolioValue ?? data.initialBalance, hours: market.hours)
    }

    // MARK: Real money

    var readinessItems: [ReadinessItem] {
        Readiness.items(trips: roundTrips, learning: learning, units: Curriculum.units)
    }

    /// Paper accounts are always allowed; live trading needs the readiness check or an adult's override.
    func liveTradingAllowed(_ env: BrokerEnvironment) -> Bool {
        guard env == .live else { return true }
        let items = readinessItems
        if Readiness.isReady(items) { return true }
        return learning.liveOverrideAt != nil && Readiness.canOverride(items)
    }

    func acceptLiveOverride() {
        guard Readiness.canOverride(readinessItems) else { return }
        mutateLearning { $0.liveOverrideAt = Date() }
    }

    func updateAge(_ age: Int) {
        let year = Calendar.current.component(.year, from: Date()) - age
        mutateLearning { state in
            var profile = state.profile ?? LearnerProfile()
            profile.birthYear = year
            state.profile = profile
        }
    }

    // MARK: Onboarding

    func completeOnboarding(name: String, profile: LearnerProfile, balance: Decimal) {
        let beginner = !profile.experience.startsUnlocked
        mutateActive { account in
            account.name = name
            account.goal = profile.goals.first?.rawValue ?? account.goal
            if account.orders.isEmpty { account.initialBalance = balance }
            account.onboardingComplete = true
            if beginner {
                account.settings.accountType = .cash
                account.settings.shortingEnabled = false
                account.settings.dailyLossLimit = (balance * Decimal(string: "0.03")!).rounded(0)
            }
        }
        mutateLearning { state in
            state.profile = profile
            state.unlocked = beginner ? [] : nil
        }
        if profile.goals.contains(.dayTrading) || profile.experience == .experienced { chartPreferences.timeframe = .m5 }
        else { chartPreferences.timeframe = .d1 }
    }

    // MARK: Drills, labs, events

    func recordDrill(_ kind: DrillKind, correct: Bool) {
        mutateLearning { $0.drills[kind.rawValue, default: DrillBox()].record(correct: correct) }
        recordAction("drill")
    }

    var dueDrills: [DrillKind] {
        DrillKind.allCases.filter { (learning.drills[$0.rawValue]?.nextDue ?? .distantPast) <= Date() }
    }

    func saveEventReplay(_ record: EventReplayRecord) {
        mutateLearning { $0.eventReplays.insert(record, at: 0) }
    }

    /// What the AI tutor knows about the learner: practice stats and the chart they're on. No personal details.
    func tutorContext() -> String {
        let stats = TradeAnalytics.stats(roundTrips)
        var lines = [
            "Experience: \(profile?.experience.rawValue ?? "unknown")",
            "Goals: \(profile?.goals.map(\.rawValue).joined(separator: "; ") ?? "unknown")",
            "Practice trades closed: \(stats.trades); win rate: \(stats.winRate.map { "\(Int($0 * 100))%" } ?? "n/a"); net: \(Format.signedMoney(stats.netPnL))",
            "Lessons finished: \(pathProgress.done) of \(pathProgress.total)",
            "Weekly coaching tip: \(weeklyReport.fix)",
            "Chart: \(chartSymbol) on the \(chartPreferences.timeframe.label) timeframe" + (market.price(chartSymbol).map { ", last price \(Format.price($0))" } ?? ""),
        ]
        let bars = market.candles(chartSymbol, chartPreferences.timeframe)
        if bars.count > 20, let last = bars.last, let first = bars.suffix(20).first {
            lines.append("Last 20 bars: from \(Format.price(first.open)) to \(Format.price(last.close)) (\(Format.percent(last.close / first.open - 1)))")
        }
        if let position = position(chartSymbol) { lines.append("Practice position: \(position.isLong ? "long" : "short") \(Format.shares(position.size)) shares") }
        return lines.joined(separator: "\n")
    }
}

extension LabStore {
    /// Sends a real order to the connected broker. Returns false (and explains) if it can't be sent.
    @discardableResult
    func placeLive(_ request: OrderRequest) -> Bool {
        guard let env = broker.environment else { notice = "Connect an Alpaca account in Settings first."; return false }
        guard liveTradingAllowed(env) else {
            notice = "Real-money trading unlocks after the practice checklist in Settings → Real-money trading."
            return false
        }
        Task {
            switch await broker.place(request) {
            case .success(let order): showToast("Sent to Alpaca: \(order.summary) · \(order.statusText.lowercased())")
            case .failure(let failure): notice = failure.message
            }
        }
        return true
    }
}


// MARK: - Learning progress

extension LabStore {
    struct LearningChallenge: Identifiable {
        let id: String
        let title: String
        let detail: String
        let complete: Bool
    }

    static let goals = ["Learn to trade", "Understand risk", "Research companies", "Build investing habits"]

    var nextLearningTitle: String {
        let goalLesson = ["Understand risk": "size", "Research companies": "stock", "Build investing habits": "etf"][data.goal] ?? "order"
        return Curriculum.lessons.first { $0.id == goalLesson && !data.completedChecks.contains(goalLesson) }?.title
            ?? Curriculum.lessons.first { !data.completedChecks.contains($0.id) }?.title ?? "Review a decision"
    }

    var challenges: [LearningChallenge] {
        [
            .init(id: "concept", title: "Check a concept", detail: "Finish a narrated preview and answer its question.",
                  complete: !features.completedBites.isEmpty),
            .init(id: "plan", title: "Write before you trade", detail: "Submit a practice order with a thesis, invalidation condition, and horizon.",
                  complete: data.orders.contains { !$0.thesis.isEmpty && !$0.invalidation.isEmpty && !$0.horizon.isEmpty }),
            .init(id: "stop", title: "Trade with a stop", detail: "Enter a position with a bracket stop loss attached.",
                  complete: data.orders.contains { $0.role == .stopLoss }),
            .init(id: "review", title: "Review a trade", detail: "Reflect on a filled order and record whether you followed your plan.",
                  complete: data.orders.contains { $0.status == .filled && !$0.reflection.isEmpty && features.tradeNotes[$0.id.uuidString]?.followedPlan != nil }),
            .init(id: "replay", title: "Replay a session", detail: "Trade a past day bar by bar in Replay.",
                  complete: !features.barReplays.isEmpty),
            .init(id: "research", title: "Save research", detail: "Save research with a note or highlighted passage.",
                  complete: features.research.contains { !$0.note.isEmpty || !$0.quote.isEmpty }),
        ]
    }

    func completeCheck(_ lessonID: String) {
        mutateActive { account in
            if !account.completedChecks.contains(lessonID) { account.completedChecks.append(lessonID) }
            if !account.completedLessons.contains(lessonID) { account.completedLessons.append(lessonID) }
        }
    }

    func completeBite(_ id: String) {
        if !workspace.features.completedBites.contains(id) { workspace.features.completedBites.append(id) }
    }

    func setTodaySection(_ section: TodaySection, visible: Bool) {
        var sections = workspace.features.todaySections
        if visible { if !sections.contains(section) { sections.append(section) } } else { sections.removeAll { $0 == section } }
        workspace.features.todaySections = sections
    }

    func setNote(_ note: TradeNote, for id: UUID) { workspace.features.tradeNotes[id.uuidString] = note }
}
