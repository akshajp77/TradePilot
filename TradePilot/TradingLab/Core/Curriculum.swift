import Foundation

nonisolated struct Lesson: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let path: String
    let title: String
    let seconds: Int
    let hook: String
    let explanation: String
    let example: String
    let question: String
    let options: [String]
    let correct: Int
    let feedback: String
    let symbol: String
}

nonisolated enum BiteKind: String, Codable, Sendable { case compound, size, limit }

nonisolated struct BiteLesson: Identifiable, Codable, Hashable, Sendable {
    static let duration: Double = 48
    static let sceneLength: Double = 12
    let id: String
    let title: String
    let subtitle: String
    let kind: BiteKind
    let captions: [String]
    let question: String
    let options: [String]
    let correct: Int
    let explanation: String
}

nonisolated struct GlossaryEntry: Identifiable, Codable, Hashable, Sendable {
    let term: String
    let explanation: String
    let example: String
    /// Other words that should open this entry ("RVOL" → "Relative volume").
    var aliases: [String]? = nil
    /// Concept drawing (see ConceptGraphic) shown with the explanation.
    var graphic: String? = nil
    var id: String { term }
    func matches(_ word: String) -> Bool {
        let w = word.lowercased()
        return term.lowercased() == w || (aliases ?? []).contains { $0.lowercased() == w }
    }
}

/// A famous market episode, replayed on daily bars with narration.
nonisolated struct HistoricalEvent: Identifiable, Codable, Hashable, Sendable {
    struct Beat: Codable, Hashable, Sendable {
        /// yyyy-MM-dd: the narration appears when this day's bar is revealed.
        let date: String
        let text: String
        /// When set, the learner chooses Hold / Sell / Buy more here.
        var decision: String? = nil
    }
    let id: String
    let title: String
    let symbol: String
    let subtitle: String
    let start: String
    let end: String
    let intro: String
    let beats: [Beat]
    let lesson: String
}

/// Scheduled economic releases that often move the whole market.
nonisolated struct EconomicEvent: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case cpi, jobs, fomc }
    let date: String
    let kind: Kind
    let title: String
    var id: String { "\(kind.rawValue)-\(date)" }

    var explanation: String {
        switch kind {
        case .cpi: return "The Consumer Price Index measures how fast everyday prices are rising (inflation). Higher-than-expected inflation can make the Fed keep interest rates high, which often pushes stocks down. Released at 8:30 AM ET, before the market opens."
        case .jobs: return "The monthly jobs report shows how many jobs the economy added and the unemployment rate. Big surprises in either direction can move the whole market at 8:30 AM ET."
        case .fomc: return "The Federal Reserve's meeting where it decides interest rates. The decision comes out at 2:00 PM ET on the last day, and prices often swing a lot in the minutes after."
        }
    }

    static func parse(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }
    var day: Date? { Self.parse(date) }
}

nonisolated struct ReplayScenario: Codable, Hashable, Sendable {
    let name: String
    let symbol: String
    let note: String
    /// Made-up numbers: never display these as a quote.
    let prices: [Double]
    let revealAt: Int
}

nonisolated struct CurriculumContent: Codable, Sendable {
    var version: Int
    var lessons: [Lesson]
    var bites: [BiteLesson]
    var glossary: [GlossaryEntry]
    var replay: ReplayScenario
    var units: [PathUnit] = []
    var events: [HistoricalEvent] = []
    var calendar: [EconomicEvent] = []

    init(version: Int, lessons: [Lesson], bites: [BiteLesson], glossary: [GlossaryEntry], replay: ReplayScenario,
         units: [PathUnit] = [], events: [HistoricalEvent] = [], calendar: [EconomicEvent] = []) {
        self.version = version; self.lessons = lessons; self.bites = bites; self.glossary = glossary; self.replay = replay
        self.units = units; self.events = events; self.calendar = calendar
    }
    private enum CodingKeys: String, CodingKey { case version, lessons, bites, glossary, replay, units, events, calendar }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        lessons = try c.decode([Lesson].self, forKey: .lessons)
        bites = try c.decode([BiteLesson].self, forKey: .bites)
        glossary = try c.decode([GlossaryEntry].self, forKey: .glossary)
        replay = try c.decode(ReplayScenario.self, forKey: .replay)
        units = try c.decodeIfPresent([PathUnit].self, forKey: .units) ?? []
        events = try c.decodeIfPresent([HistoricalEvent].self, forKey: .events) ?? []
        calendar = try c.decodeIfPresent([EconomicEvent].self, forKey: .calendar) ?? []
    }

    static let empty = CurriculumContent(version: 0, lessons: [], bites: [], glossary: [],
                                         replay: ReplayScenario(name: "", symbol: "", note: "", prices: [], revealAt: 0))

    var pathLessons: [PathLesson] { units.flatMap(\.lessons) }
    func unit(of lessonID: String) -> PathUnit? { units.first { $0.lessons.contains { $0.id == lessonID } } }
    func pathLesson(_ id: String) -> PathLesson? { pathLessons.first { $0.id == id } }
    /// The lesson that unlocks a feature.
    func lesson(unlocking feature: LabFeature) -> PathLesson? { pathLessons.first { $0.unlocks.contains(feature) } }
    func glossaryEntry(_ word: String) -> GlossaryEntry? {
        glossary.first { $0.term.lowercased() == word.lowercased() } ?? glossary.first { $0.matches(word) }
    }

    /// Human-readable problems; empty when the content is usable.
    func problems() -> [String] {
        var issues: [String] = []
        if Set(lessons.map(\.id)).count != lessons.count { issues.append("duplicate lesson id") }
        for lesson in lessons where !lesson.options.indices.contains(lesson.correct) { issues.append("lesson \(lesson.id): correct index out of range") }
        for bite in bites {
            if bite.captions.count != Int(BiteLesson.duration / BiteLesson.sceneLength) { issues.append("bite \(bite.id): needs 4 captions") }
            if !bite.options.indices.contains(bite.correct) { issues.append("bite \(bite.id): correct index out of range") }
        }
        if !replay.prices.isEmpty && !(1..<replay.prices.count).contains(replay.revealAt) { issues.append("replay: revealAt out of range") }
        let pathIDs = pathLessons.map(\.id)
        if Set(pathIDs).count != pathIDs.count { issues.append("duplicate path lesson id") }
        for lesson in pathLessons {
            if lesson.pages.isEmpty { issues.append("path \(lesson.id): no pages") }
            if lesson.quiz.isEmpty { issues.append("path \(lesson.id): no quiz") }
            for q in lesson.quiz where !q.options.indices.contains(q.correct) { issues.append("path \(lesson.id): correct index out of range") }
            for term in lesson.terms where glossaryEntry(term) == nil { issues.append("path \(lesson.id): unknown term \(term)") }
        }
        let terms = glossary.map { $0.term.lowercased() }
        if Set(terms).count != terms.count { issues.append("duplicate glossary term") }
        for event in events {
            if EconomicEvent.parse(event.start) == nil || EconomicEvent.parse(event.end) == nil { issues.append("event \(event.id): bad dates") }
            for beat in event.beats where EconomicEvent.parse(beat.date) == nil { issues.append("event \(event.id): bad beat date \(beat.date)") }
        }
        for item in calendar where item.day == nil { issues.append("calendar: bad date \(item.date)") }
        return issues
    }
}

/// Lesson text ships as Resources/Lessons.json so it can be edited and localized without touching code.
nonisolated enum Curriculum {
    static let content: CurriculumContent = load(Bundle.main.url(forResource: "Lessons", withExtension: "json"))

    static var lessons: [Lesson] { content.lessons }
    static var bites: [BiteLesson] { content.bites }
    static var glossary: [GlossaryEntry] { content.glossary }
    static var replay: ReplayScenario { content.replay }
    static var units: [PathUnit] { content.units }
    static var events: [HistoricalEvent] { content.events }
    static var calendar: [EconomicEvent] { content.calendar }
    static func term(_ word: String) -> GlossaryEntry? { content.glossaryEntry(word) }
    static var isMissing: Bool { content.version == 0 }

    static func load(_ url: URL?) -> CurriculumContent {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CurriculumContent.self, from: data) else {
            assertionFailure("Lessons.json is missing from the app bundle or invalid")
            return .empty
        }
        assert(decoded.problems().isEmpty, "Lessons.json problems: \(decoded.problems())")
        return decoded
    }
}
