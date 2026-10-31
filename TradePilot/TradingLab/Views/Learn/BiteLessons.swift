import SwiftUI
import Charts
import AVFoundation
import Combine

enum LessonScene {
    static func phase(_ elapsed: Double) -> Int { min(3, max(0, Int(elapsed / BiteLesson.sceneLength))) }
    static func year(_ elapsed: Double) -> Double {
        if elapsed < 12 { return min(1, max(0, elapsed / 1.6)) }
        return 1 + 9 * min(1, max(0, (elapsed - 12) / 3))
    }
    static func simple(rate: Double, year: Double) -> Double { 1000 * (1 + rate / 100 * year) }
    static func compound(rate: Double, year: Double) -> Double { 1000 * pow(1 + rate / 100, year) }
    static func accountLoss(size: Double) -> Double { size * 0.20 }
    static let prices: [Double] = [106, 105, 103, 102, 100, 99, 98]
    static func priceStep(_ elapsed: Double) -> Double {
        if elapsed < 12 { return 2 * min(1, max(0, elapsed / 2)) }
        if elapsed < 24 { return 2 }
        return 2 + 4 * min(1, max(0, (elapsed - 24) / 2.4))
    }
    static func price(at step: Double) -> Double {
        let value = min(Double(prices.count - 1), max(0, step))
        let index = Int(value), next = min(prices.count - 1, index + 1)
        return prices[index] + (prices[next] - prices[index]) * (value - Double(index))
    }
}

/// Lesson clock. Elapsed time is derived from a start date, so animation frames are drawn by a
/// TimelineView without publishing state 20 times a second. Published state changes only on
/// play/pause, scene changes and narration holds.
@MainActor
final class LessonPlayback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var beat = 0
    @Published private(set) var sound = true
    @Published var voiceID: String {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: PreferenceKeys.narratorVoice)
            speech.stopSpeaking(at: .immediate)
            spokenBeat = -1
            if playing && sound { narrate() }
        }
    }
    let voices: [AVSpeechSynthesisVoice]
    let lesson: BiteLesson

    private let speech = AVSpeechSynthesizer()
    private var anchorDate = Date()
    private var anchorElapsed = 0.0
    /// While narration of a scene is still speaking, the clock holds just before the next scene.
    private var hold: Double?
    private var spokenBeat = -1
    private var ticker: Task<Void, Never>?

    init(lesson: BiteLesson) {
        self.lesson = lesson
        let naturalNames = ["Ava", "Zoe", "Evan", "Tom", "Allison", "Samantha", "Daniel", "Serena", "Karen", "Moira", "Tessa", "Alex"]
        voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en-") && ($0.quality != .default || naturalNames.contains(where: $0.name.hasPrefix))
        }.sorted {
            func score(_ voice: AVSpeechSynthesisVoice) -> Int {
                (voice.quality == .premium ? 200 : voice.quality == .enhanced ? 100 : 0) + (voice.language == "en-US" ? 20 : 0) + (voice.name.hasPrefix("Ava") ? 5 : 0)
            }
            return score($0) == score($1) ? $0.name < $1.name : score($0) > score($1)
        }
        let saved = UserDefaults.standard.string(forKey: PreferenceKeys.narratorVoice)
        voiceID = voices.first(where: { $0.identifier == saved })?.identifier ?? voices.first?.identifier
            ?? AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? ""
        super.init()
        speech.delegate = self
    }

    func elapsed(at date: Date = Date()) -> Double {
        guard playing else { return anchorElapsed }
        let running = anchorElapsed + max(0, date.timeIntervalSince(anchorDate))
        return min(hold ?? BiteLesson.duration, running, BiteLesson.duration)
    }
    var finished: Bool { elapsed() >= BiteLesson.duration }

    func play() {
        if finished { anchorElapsed = 0; spokenBeat = -1; beat = 0 }
        anchorDate = Date()
        hold = nil
        playing = true
        if sound {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            if speech.isPaused { speech.continueSpeaking() } else { narrate() }
        }
        startTicker()
    }

    func pause() {
        anchorElapsed = elapsed()
        playing = false
        ticker?.cancel()
        speech.pauseSpeaking(at: .immediate)
    }

    func stop() {
        anchorElapsed = elapsed()
        playing = false
        ticker?.cancel()
        spokenBeat = -1
        speech.stopSpeaking(at: .immediate)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func seek(_ time: Double) {
        anchorElapsed = min(BiteLesson.duration, max(0, time))
        anchorDate = Date()
        hold = nil
        spokenBeat = -1
        beat = LessonScene.phase(anchorElapsed)
        speech.stopSpeaking(at: .immediate)
        if anchorElapsed >= BiteLesson.duration { stop() } else if playing { narrate() }
    }

    func toggleSound() {
        sound.toggle()
        speech.stopSpeaking(at: .immediate)
        spokenBeat = -1
        hold = nil
        if sound && playing { narrate() }
    }

    /// Four checks a second for scene changes, narration and the end. Frames are not driven from here.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard playing else { return }
        let now = elapsed()
        let scene = LessonScene.phase(now)
        // Finish each sentence before the next scene; never chop narration at a scene boundary.
        if sound && speech.isSpeaking && hold == nil && scene == beat {
            let boundary = Double(beat + 1) * BiteLesson.sceneLength - 0.01
            if boundary - now < 0.3 { hold = boundary }
        }
        if scene != beat { beat = scene }
        if now >= BiteLesson.duration { stop(); return }
        if sound && spokenBeat != beat && !speech.isSpeaking { narrate() }
    }

    private func narrate() {
        guard sound && playing, lesson.captions.indices.contains(beat) else { return }
        spokenBeat = beat
        let utterance = AVSpeechUtterance(string: lesson.captions[beat])
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.02
        utterance.postUtteranceDelay = 0.15
        speech.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.releaseHold() }
    }

    private func releaseHold() {
        guard let held = hold else { return }
        anchorElapsed = held + 0.02
        anchorDate = Date()
        hold = nil
    }
}

struct BiteLessonPreviews: View {
    @Environment(\.theme) private var base
    private var theme: Theme { base.learning }
    @ObservedObject var store: LabStore
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Short lessons").font(theme.section)
            ForEach(Curriculum.bites) { lesson in
                NavigationLink { BiteLessonPlayer(store: store, lesson: lesson) } label: {
                    HStack(spacing: Space.s12) {
                        LessonThumbnail(kind: lesson.kind).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(lesson.title).font(theme.label).foregroundStyle(theme.ink)
                            Text(lesson.subtitle).font(theme.meta).foregroundStyle(theme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: store.features.completedBites.contains(lesson.id) ? "checkmark" : "play.fill")
                            .font(theme.meta).foregroundStyle(theme.accent)
                    }.padding(.vertical, Space.s8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Rule()
            }
        }
    }
}

struct LessonThumbnail: View {
    @Environment(\.theme) private var base
    let kind: BiteKind
    var body: some View {
        let theme = base.learning
        Canvas { context, size in
            switch kind {
            case .compound:
                for compound in [false, true] {
                    var path = Path()
                    for i in 0...20 {
                        let x = 8 + CGFloat(i) / 20 * (size.width - 16)
                        let amount = compound ? pow(1.06, Double(i) / 2) - 1 : 0.06 * Double(i) / 2
                        let point = CGPoint(x: x, y: size.height - 8 - amount * (size.height - 16))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(compound ? theme.accent : theme.orange), lineWidth: 2)
                }
            case .size:
                for i in 0..<16 {
                    let color = i == 0 ? theme.loss : i < 8 ? theme.accent : theme.line
                    context.fill(Path(CGRect(x: 8 + CGFloat(i % 4) * 12, y: 8 + CGFloat(i / 4) * 12, width: 8, height: 8)), with: .color(color))
                }
            case .limit:
                var path = Path()
                path.move(to: CGPoint(x: 8, y: 14)); path.addLine(to: CGPoint(x: 28, y: 21))
                path.addLine(to: CGPoint(x: 42, y: 42)); path.addLine(to: CGPoint(x: 56, y: 48))
                context.stroke(path, with: .color(theme.accent), lineWidth: 2)
                var rule = Path()
                rule.move(to: CGPoint(x: 8, y: 34)); rule.addLine(to: CGPoint(x: 56, y: 34))
                context.stroke(rule, with: .color(theme.orange), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            }
        }
        .background(theme.line.opacity(0.20), in: RoundedRectangle(cornerRadius: Space.smallRadius))
        .accessibilityHidden(true)
    }
}

struct LessonGraphic: View {
    @Environment(\.theme) private var base
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: BiteKind
    let elapsed: Double
    @Binding var control: Double
    @Binding var adjustedSize: Bool
    private var theme: Theme { base.learning }
    private var phase: Int { LessonScene.phase(elapsed) }
    private var year: Double { reduceMotion ? (phase == 0 ? 1 : 10) : LessonScene.year(elapsed) }
    private var size: Double { adjustedSize ? control : phase < 2 ? 10 : 50 }
    private var step: Double { reduceMotion ? (phase < 2 ? 2 : 6) : LessonScene.priceStep(elapsed) }
    private var quote: Double { LessonScene.price(at: step) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            switch kind {
            case .compound: compoundGraphic
            case .size: sizeGraphic
            case .limit: limitGraphic
            }
        }
        .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        .overlay(RoundedRectangle(cornerRadius: Space.radius).stroke(theme.line))
        .tint(theme.accent)
    }

    private func value(_ title: String, _ amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(title).font(theme.meta).foregroundStyle(theme.muted) }
            Text(amount.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                .font(theme.section).monospacedDigit().foregroundStyle(color).contentTransition(.numericText())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compoundGraphic: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack { Text("$1,000 · \(Int(control))% per year"); Spacer(); Text("Year \(Int(year.rounded()))").monospacedDigit() }
                .font(theme.meta).foregroundStyle(theme.muted)
            HStack {
                value("Simple", LessonScene.simple(rate: control, year: year), color: theme.orange)
                value("Compound", LessonScene.compound(rate: control, year: year), color: theme.accent)
            }
            Chart {
                ForEach(0..<2, id: \.self) { method in
                    ForEach(0...20, id: \.self) { index in
                        let x = min(Double(index) / 2, year)
                        let amount = method == 0 ? LessonScene.simple(rate: control, year: x) : LessonScene.compound(rate: control, year: x)
                        LineMark(x: .value("Year", x), y: .value("Balance", amount), series: .value("Method", method))
                            .foregroundStyle(method == 0 ? theme.orange : theme.accent).lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    let balance = method == 0 ? LessonScene.simple(rate: control, year: year) : LessonScene.compound(rate: control, year: year)
                    PointMark(x: .value("Year", year), y: .value("Balance", balance)).foregroundStyle(method == 0 ? theme.orange : theme.accent)
                }
            }
            .chartXScale(domain: 0...10).chartYScale(domain: 1000...max(1800, LessonScene.compound(rate: control, year: 10) * 1.05))
            .chartXAxis { AxisMarks(values: [0, 5, 10]) { _ in AxisValueLabel(); AxisGridLine().foregroundStyle(theme.line) } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .currency(code: "USD").precision(.fractionLength(0))); AxisGridLine().foregroundStyle(theme.line) } }
            .frame(height: 165)
            .accessibilityLabel("Simple interest \(Int(LessonScene.simple(rate: control, year: year))) dollars. Compound interest \(Int(LessonScene.compound(rate: control, year: year))) dollars at year \(Int(year)).")
            Text(phase == 0 ? "Both earn interest on $1,000 in year one."
                 : "\((LessonScene.compound(rate: control, year: year) - LessonScene.simple(rate: control, year: year)).formatted(.currency(code: "USD").precision(.fractionLength(0)))) extra from reinvesting interest")
                .font(theme.label).foregroundStyle(phase == 0 ? theme.muted : theme.teal)
            HStack { Text("Annual rate"); Spacer(); Text("\(Int(control))%").monospacedDigit() }.font(theme.meta)
            Slider(value: $control, in: 2...12, step: 1).accessibilityLabel("Annual interest rate")
            Text("Fixed-rate illustration. No added deposits.").font(theme.meta).foregroundStyle(theme.muted)
        }
    }

    private var sizeGraphic: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text(phase == 0 ? "$1,000 account · cash + one stock" : "Stock falls 20% · cash stays constant").font(theme.meta).foregroundStyle(theme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 10), spacing: 5) {
                ForEach(0..<50, id: \.self) { index in
                    let exposed = Double(index) < size / 2
                    let lost = phase > 0 && Double(index) < LessonScene.accountLoss(size: size) / 2
                    RoundedRectangle(cornerRadius: 2).fill(lost ? theme.loss : exposed ? theme.accent : theme.line.opacity(0.6)).aspectRatio(1, contentMode: .fit)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: phase)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: size)
            .accessibilityLabel("Each square is two percent of the account. \(Int(size)) percent invested; \(phase == 0 ? 0 : Int(LessonScene.accountLoss(size: size))) percent lost.")
            HStack(spacing: 12) { legend("Stock", theme.accent); legend("Cash", theme.line); legend("Loss", theme.loss) }
            if phase > 0 {
                lossRow("10% position", size: 10)
                if phase >= 2 { lossRow("\(Int(size))% position", size: size) }
            } else {
                HStack { value("Stock", 1000 * size / 100, color: theme.accent); value("Cash", 1000 * (1 - size / 100), color: theme.muted) }
            }
            HStack { Text("Amount invested"); Spacer(); Text("\(Int(size))%").monospacedDigit() }.font(theme.meta)
            Slider(value: Binding(get: { size }, set: { control = $0; adjustedSize = true }), in: 2...100, step: 2).accessibilityLabel("Position size percent")
            Text(phase == 0 ? "Each square is 2% of the account." : "\(Int(size))% × 20% = \(LessonScene.accountLoss(size: size).formatted(.number.precision(.fractionLength(1))))% account loss")
                .font(theme.label).foregroundStyle(phase == 0 ? theme.muted : theme.loss)
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(text) }.font(theme.meta).foregroundStyle(theme.muted)
    }

    private func lossRow(_ title: String, size: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(theme.meta).frame(width: 88, alignment: .leading)
            GeometryReader { geometry in
                Rectangle().fill(theme.loss.opacity(0.12))
                    .overlay(alignment: .leading) { Rectangle().fill(theme.loss).frame(width: geometry.size.width * size / 100) }
            }.frame(height: 8)
            Text("−\(LessonScene.accountLoss(size: size).formatted(.number.precision(.fractionLength(1))))%")
                .font(theme.meta).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private var limitGraphic: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack { value("Available price", quote, color: theme.accent); value("Buy limit", control, color: theme.orange) }
            Chart {
                ForEach(0...6, id: \.self) { index in
                    let x = min(Double(index), step)
                    LineMark(x: .value("Step", x), y: .value("Price", LessonScene.price(at: x))).foregroundStyle(theme.accent).lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                RuleMark(y: .value("Buy limit", control)).foregroundStyle(theme.orange).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                PointMark(x: .value("Now", step), y: .value("Price", quote)).foregroundStyle(quote <= control ? theme.teal : theme.accent)
            }
            .chartXScale(domain: 0...6).chartYScale(domain: 88...112).chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [90, 100, 110]) { _ in AxisGridLine().foregroundStyle(theme.line); AxisValueLabel(format: .currency(code: "USD").precision(.fractionLength(0))) } }
            .frame(height: 165)
            HStack {
                Circle().fill(quote <= control ? theme.teal : theme.orange).frame(width: 7, height: 7)
                Text(quote <= control ? "Price condition met" : "Waiting above your limit").font(theme.label)
            }.foregroundStyle(quote <= control ? theme.teal : theme.orange)
            Text(quote <= control ? "Eligible for a fill; execution still depends on available shares."
                 : "\(quote.formatted(.currency(code: "USD").precision(.fractionLength(0)))) is above your \(control.formatted(.currency(code: "USD").precision(.fractionLength(0)))) ceiling.")
                .font(theme.meta).foregroundStyle(theme.muted).frame(minHeight: 32, alignment: .topLeading)
            HStack { Text("Your maximum price"); Spacer(); Text(control.formatted(.currency(code: "USD").precision(.fractionLength(0)))).monospacedDigit() }.font(theme.meta)
            Slider(value: $control, in: 90...110, step: 1).accessibilityLabel("Maximum buy price")
        }
    }
}

struct BiteLessonPlayer: View {
    @Environment(\.theme) private var base
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: LabStore
    let lesson: BiteLesson
    @StateObject private var player: LessonPlayback
    @State private var control: Double
    @State private var adjustedSize = false
    @State private var answer: Int?
    private var theme: Theme { base.learning }

    init(store: LabStore, lesson: BiteLesson) {
        self.store = store
        self.lesson = lesson
        _player = StateObject(wrappedValue: LessonPlayback(lesson: lesson))
        _control = State(initialValue: lesson.kind == .compound ? 6 : lesson.kind == .size ? 10 : 100)
    }

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text(lesson.title).font(theme.page)
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(index <= player.beat ? theme.accent : theme.line).frame(height: 3)
                    }
                }.accessibilityLabel("Scene \(player.beat + 1) of four")
                // ~12 frames a second while playing; paused timelines draw nothing extra.
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !player.playing)) { context in
                    LessonGraphic(kind: lesson.kind, elapsed: player.elapsed(at: context.date), control: $control, adjustedSize: $adjustedSize)
                }
                Text(lesson.captions.indices.contains(player.beat) ? lesson.captions[player.beat] : "")
                    .font(theme.body).lineSpacing(4).frame(minHeight: 84, alignment: .topLeading)
                HStack {
                    Button { player.playing ? player.pause() : player.play() } label: {
                        Label(player.playing ? "Pause" : player.finished ? "Replay" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill")
                    }.buttonStyle(.plain)
                    Spacer()
                    Menu {
                        if !player.voices.contains(where: { $0.quality == .premium || $0.quality == .enhanced }) {
                            Text("For more natural narration, download an Enhanced or Premium English voice in system settings.")
                        }
                        Button(player.sound ? "Turn narration off" : "Turn narration on") { player.toggleSound() }
                        if !player.voices.isEmpty {
                            Picker("Voice", selection: $player.voiceID) {
                                ForEach(player.voices, id: \.identifier) { voice in
                                    Text(voice.name + (voice.quality == .premium ? " · Premium" : voice.quality == .enhanced ? " · Enhanced" : "")).tag(voice.identifier)
                                }
                            }
                        }
                    } label: { Image(systemName: player.sound ? "speaker.wave.2" : "speaker.slash").frame(width: 44, height: 44) }
                        .accessibilityLabel("Narration and voice")
                }.font(theme.label).foregroundStyle(theme.accent)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: Space.s8) {
                        Slider(value: Binding(get: { player.elapsed(at: context.date) }, set: { player.seek($0) }), in: 0...BiteLesson.duration)
                            .accessibilityLabel("Lesson progress in seconds")
                        HStack {
                            Text("\(Int(player.elapsed(at: context.date))) / \(Int(BiteLesson.duration)) sec").monospacedDigit()
                            Spacer()
                            Button("Next scene") { player.seek(Double(player.beat + 1) * BiteLesson.sceneLength) }.disabled(player.beat >= 3)
                        }.font(theme.meta).foregroundStyle(theme.muted)
                    }
                }
                Rule()
                DisclosureGroup("Quick check") {
                    VStack(alignment: .leading, spacing: Space.s12) {
                        Text(lesson.question)
                        ForEach(lesson.options.indices, id: \.self) { index in
                            Button {
                                answer = index
                                if index == lesson.correct { store.completeBite(lesson.id) }
                            } label: {
                                HStack {
                                    Text(lesson.options[index]).multilineTextAlignment(.leading)
                                    Spacer()
                                    if answer == index { Image(systemName: index == lesson.correct ? "checkmark" : "arrow.counterclockwise") }
                                }
                                .font(theme.label).padding(Space.s12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                                .overlay(RoundedRectangle(cornerRadius: Space.smallRadius).stroke(answer == index ? theme.accent : theme.line))
                            }.buttonStyle(.plain)
                        }
                        if answer != nil { Text(lesson.explanation).font(theme.meta).foregroundStyle(theme.muted) }
                    }.padding(.top, Space.s12)
                }.font(theme.label)
            }
        }
        .learningTheme()
        .navigationTitle("").appInlineTitle()
        .onChange(of: scenePhase) { _, value in if value != .active { player.pause() } }
        .onDisappear { player.stop() }
    }
}
