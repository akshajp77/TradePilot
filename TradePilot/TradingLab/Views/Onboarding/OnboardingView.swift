import SwiftUI
import AuthenticationServices

/// First-run questions, one at a time, each fading in and out, then account creation.
/// `profileOnly` asks the learning questions of people who set up the app before onboarding existed.
struct OnboardingView: View {
    enum Mode { case full, profileOnly }
    enum Step: Int, CaseIterable { case welcome, name, greet, age, experience, goals, time, risk, balance, account, plan }

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: LabStore
    @ObservedObject var account: AccountService
    var mode: Mode = .full

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var age = 18
    @State private var ageChosen = false
    @State private var experience: Experience?
    @State private var goals: Set<LearnerGoal> = []
    @State private var time: WeeklyTime?
    @State private var risk: RiskComfort?
    @State private var balance: Decimal?
    @FocusState private var nameFocused: Bool

    init(store: LabStore, account: AccountService, mode: Mode = .full) {
        self.store = store
        self.account = account
        self.mode = mode
        _step = State(initialValue: mode == .full ? .welcome : .age)
        _name = State(initialValue: store.data.name)
    }

    private var steps: [Step] {
        mode == .full ? Step.allCases : [.age, .experience, .goals, .time, .risk, .plan]
    }
    private var firstName: String { name.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "" }

    var body: some View {
        ZStack {
            theme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                if step != .welcome && step != .greet {
                    HStack {
                        if canGoBack {
                            Button { go(back: true) } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44) }
                                .buttonStyle(.plain).accessibilityLabel("Back")
                        }
                        ProgressView(value: Double(progressIndex), total: Double(steps.count - 1)).tint(theme.accent)
                        if mode == .profileOnly {
                            Button("Later") { dismiss() }.font(theme.meta)
                        }
                    }
                    .padding(.horizontal, Space.s16).padding(.top, Space.s8)
                    .transition(.opacity)
                }
                ZStack { current.id(step).transition(.opacity) }
                    .frame(maxWidth: 560, maxHeight: .infinity)
                    .padding(.horizontal, Space.s24)
            }
        }
    }

    private var progressIndex: Int { steps.firstIndex(of: step) ?? 0 }
    private var canGoBack: Bool { progressIndex > 0 && step != .plan }

    @ViewBuilder private var current: some View {
        switch step {
        case .welcome: welcome
        case .name: nameStep
        case .greet: greet
        case .age: ageStep
        case .experience:
            Question(title: "How much have you traded before?", subtitle: "No wrong answer. This sets where you start.") {
                ForEach(Experience.allCases) { option in
                    Choice(text: option.rawValue, selected: experience == option) { experience = option; advance(after: 0.35) }
                }
            }
        case .goals:
            Question(title: "What do you want from Trading Lab?", subtitle: "Pick all that fit.") {
                ForEach(LearnerGoal.allCases) { goal in
                    Choice(text: goal.rawValue, icon: goal.symbolName, selected: goals.contains(goal), multi: true) {
                        if goals.contains(goal) { goals.remove(goal) } else { goals.insert(goal) }
                    }
                }
                ActionButton(title: "Continue", disabled: goals.isEmpty) { go() }.padding(.top, Space.s8)
            }
        case .time:
            Question(title: "How much time can you spend each week?", subtitle: "Lessons take 3–5 minutes each.") {
                ForEach(WeeklyTime.allCases) { option in
                    Choice(text: option.rawValue, selected: time == option) { time = option; advance(after: 0.35) }
                }
            }
        case .risk: riskStep
        case .balance: balanceStep
        case .account: accountStep
        case .plan: planStep
        }
    }

    // MARK: Steps

    private var welcome: some View {
        Question(title: "Learn the stock market by doing it, safely.", subtitle: "Trading Lab gives you pretend money to practice with, lessons in plain English, and a coach that helps you build good habits before any real money is involved.", large: true) {
            ActionButton(title: "Get started") { go() }.padding(.top, Space.s16)
        }
    }

    private var nameStep: some View {
        Question(title: "First, what should we call you?", subtitle: "Your first name or a nickname.") {
            TextField("Name", text: $name)
                .font(.system(size: 28, weight: .semibold))
                .appCapitalization(.words).autocorrectionDisabled()
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit { if !firstName.isEmpty { go() } }
                .padding(.vertical, Space.s12)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.accent).frame(height: 2) }
            ActionButton(title: "Continue", disabled: firstName.isEmpty) { go() }.padding(.top, Space.s16)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { nameFocused = true } }
    }

    private var greet: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Spacer()
            FadeInText(text: "Nice to meet you, \(firstName).", font: theme.display, delay: 0.1)
            FadeInText(text: "A few quick questions so we can set things up for you.", font: theme.body, color: theme.muted, delay: 0.7)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            try? await Task.sleep(for: .seconds(2.4))
            if step == .greet { go() }
        }
    }

    private var ageStep: some View {
        Question(title: mode == .full ? "How old are you, \(firstName)?" : "How old are you?", subtitle: "We use this to keep things appropriate. Real-money trading needs you to be 18 or older.") {
            Picker("Age", selection: Binding(get: { age }, set: { age = $0; ageChosen = true })) {
                ForEach(10...99, id: \.self) { Text("\($0)").tag($0) }
            }
            #if os(iOS)
            .pickerStyle(.wheel)
            #endif
            .frame(height: 150)
            if age < 13 {
                Text("Trading Lab is for people 13 and older. Ask a parent or teacher about beginner money lessons made for your age.")
                    .font(theme.label).foregroundStyle(theme.loss).transition(.opacity)
            } else if age < 18 {
                Text("You can use everything in practice mode. Real-money trading stays locked until you're 18.")
                    .font(theme.meta).foregroundStyle(theme.muted).transition(.opacity)
            }
            ActionButton(title: "Continue", disabled: age < 13) { go() }.padding(.top, Space.s8)
        }
        .animation(.easeInOut(duration: 0.25), value: age < 18)
    }

    private var riskStep: some View {
        Question(title: "Imagine your $1,000 dropped to $800 in a week. What would you most likely do?", subtitle: "Be honest. It helps us coach you.") {
            ForEach(RiskComfort.allCases) { option in
                Choice(text: option.rawValue, selected: risk == option) { risk = option }
            }
            if let risk {
                Text(risk.insight).font(theme.body).foregroundStyle(theme.muted)
                    .padding(Space.s12).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
                    .transition(.opacity)
                ActionButton(title: "Continue") { go() }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: risk)
    }

    private var balanceStep: some View {
        Question(title: "How much pretend money do you want to practice with?", subtitle: "Pick close to what you'd really have. Practicing with $100,000 when you'd really trade $1,000 builds the wrong habits.") {
            ForEach([Decimal(1_000), 5_000, 25_000, 100_000], id: \.self) { amount in
                Choice(text: Format.money(amount), selected: balance == amount) { balance = amount; advance(after: 0.35) }
            }
        }
    }

    private var accountStep: some View {
        Question(title: "Create your account", subtitle: "Sign in with Apple, Google or your email to save your progress and use it on your other devices. There's no password to remember, and your trades stay private unless you choose to share them.") {
            if account.signedIn {
                Label("Account created", systemImage: "checkmark.circle.fill").font(theme.section).foregroundStyle(theme.accent)
                    .task { try? await Task.sleep(for: .seconds(0.8)); if step == .account { go() } }
            } else {
                SignInWithAppleButton(.signUp) { request in
                    account.prepare(request)
                } onCompletion: { result in
                    Task {
                        if let message = await account.complete(result) { store.notice = message }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .disabled(account.busy)
                GoogleSignInButton(account: account) { store.notice = $0 }
                EmailSignInView(account: account) { store.notice = $0 }
                if account.busy { ProgressView() }
                Button("Continue without an account") { go() }
                    .font(theme.meta).foregroundStyle(theme.muted).padding(.top, Space.s8)
                Text("Without an account, your progress stays on this device only. You can sign in later from Settings.")
                    .font(theme.meta).foregroundStyle(theme.muted)
            }
        }
    }

    private var planStep: some View {
        let beginner = !(experience ?? .none).startsUnlocked
        return Question(title: mode == .full ? "You're all set, \(firstName)." : "Thanks! Here's your plan.", subtitle: nil, large: true) {
            VStack(alignment: .leading, spacing: Space.s12) {
                planRow("book.closed", beginner ? "Start with Unit 1: Stock market basics. Each lesson is a few minutes and ends with a practice task." :
                            "Jump to any unit in Learn. You already know the basics, so start wherever you like.")
                planRow("lock.open", beginner ? "Advanced tools (short selling, borrowed money, special orders) unlock as you finish the lessons that explain them." :
                            "All practice tools are unlocked.")
                planRow("shield", mode == .full ? "A daily loss limit is \(beginner ? "on" : "available in Settings") to stop a bad day from snowballing." :
                            "Your coach will flag risky trades and review every trade you close.")
                if goals.contains(.dayTrading) { planRow("bolt", "Day trading tools are in the Chart and Scan tabs. Try bar replay to practice whole days quickly.") }
                if goals.contains(.investing) { planRow("leaf", "See what steady investing did with real S&P 500 prices in Learn → Investing vs trading.") }
                planRow("dollarsign.circle", age >= 18 ? "Real-money trading (Alpaca) unlocks after you've practiced: 50 trades, 8 weeks, good habits." :
                            "Everything here is practice mode. Real-money trading stays off until you're 18.")
            }
            ActionButton(title: "Let's go") { finish() }.padding(.top, Space.s16)
        }
    }

    private func planRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 26)
            Text(text).font(theme.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Navigation

    private func go(back: Bool = false) {
        guard let index = steps.firstIndex(of: step) else { return }
        var next = back ? index - 1 : index + 1
        if back && steps.indices.contains(next) && steps[next] == .greet { next -= 1 }
        guard steps.indices.contains(next) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { step = steps[next] }
    }

    private func advance(after seconds: Double) {
        let current = step
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if step == current { go() } }
    }

    private func finish() {
        let year = Calendar.current.component(.year, from: Date()) - age
        let profile = LearnerProfile(birthYear: year, experience: experience ?? .none, goals: LearnerGoal.allCases.filter(goals.contains),
                                     weeklyTime: time ?? .some, riskComfort: risk)
        if mode == .full {
            store.completeOnboarding(name: name.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile, balance: balance ?? 10_000)
        } else {
            store.mutateLearning { $0.profile = profile }
            dismiss()
        }
    }
}

/// Title fades in, then the answers fade in just after.
private struct Question<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let subtitle: String?
    var large = false
    @ViewBuilder let content: Content
    @State private var showTitle = false
    @State private var showContent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s24) {
                Spacer(minLength: large ? 80 : 40)
                VStack(alignment: .leading, spacing: Space.s12) {
                    Text(title).font(large ? theme.display : theme.page).tracking(large ? -1 : -0.4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(theme.body).foregroundStyle(theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                }
                .opacity(showTitle ? 1 : 0)
                .offset(y: showTitle || reduceMotion ? 0 : 8)
                VStack(alignment: .leading, spacing: Space.s12) { content }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent || reduceMotion ? 0 : 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Space.s32)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.5).delay(0.1)) { showTitle = true }
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.5).delay(0.45)) { showContent = true }
        }
    }
}

private struct Choice: View {
    @Environment(\.theme) private var theme
    let text: String
    var icon: String? = nil
    let selected: Bool
    var multi = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s12) {
                if let icon { Image(systemName: icon).frame(width: 22).foregroundStyle(theme.accent) }
                Text(text).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: selected ? (multi ? "checkmark.square.fill" : "checkmark.circle.fill") : (multi ? "square" : "circle"))
                    .foregroundStyle(selected ? theme.accent : theme.line)
            }
            .font(theme.label)
            .padding(.horizontal, Space.s16).frame(minHeight: 54)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
            .overlay(RoundedRectangle(cornerRadius: Space.radius).stroke(selected ? theme.accent : theme.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

private struct FadeInText: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let font: Font
    var color: Color? = nil
    var delay: Double = 0
    @State private var visible = false
    var body: some View {
        Text(text).font(font).foregroundStyle(color ?? theme.ink).fixedSize(horizontal: false, vertical: true)
            .opacity(visible ? 1 : 0).offset(y: visible || reduceMotion ? 0 : 10)
            .onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.7).delay(delay)) { visible = true } }
    }
}

/// Shown in Learn for people who set up the app before these questions existed.
struct AboutYouCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: LabStore
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: Space.s12) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 26)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tell us about you").font(theme.label)
                    Text("Five quick questions to personalize your lessons and coaching.").font(theme.meta).foregroundStyle(theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(theme.muted)
            }
            .padding(Space.s16).background(theme.surface, in: RoundedRectangle(cornerRadius: Space.radius))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            OnboardingView(store: store, account: store.account, mode: .profileOnly).environment(\.theme, theme)
        }
    }
}
