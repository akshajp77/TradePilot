import SwiftUI

struct Rule: View {
    @Environment(\.theme) private var theme
    var body: some View { Rectangle().fill(theme.line).frame(height: 1) }
}

struct Eyebrow: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text.uppercased()).font(theme.meta.weight(.medium)).tracking(1.4).foregroundStyle(theme.muted)
    }
}

struct ActionButton: View {
    @Environment(\.theme) private var theme
    let title: String
    var secondary = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(theme.label).tracking(0.15).frame(maxWidth: .infinity).frame(minHeight: 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? theme.muted : secondary ? theme.accent : .white)
        .background(disabled ? theme.line : secondary ? theme.surface : theme.buttonFill,
                    in: RoundedRectangle(cornerRadius: Space.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: Space.smallRadius).stroke(secondary && !disabled ? theme.accent : .clear, lineWidth: 1))
        .disabled(disabled)
    }
}

struct PageBackground: View {
    @Environment(\.theme) private var theme
    var atmosphere = false
    var body: some View {
        theme.paper.overlay {
            if atmosphere && theme.kind == .ethereal && !theme.isLearning {
                LinearGradient(colors: [theme.accent.opacity(0.09), .clear, theme.accent.opacity(0.025)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea()
    }
}

struct Page<Content: View>: View {
    let content: Content
    var mainAtmosphere: Bool
    init(mainAtmosphere: Bool = false, @ViewBuilder content: () -> Content) {
        self.mainAtmosphere = mainAtmosphere
        self.content = content()
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(width: max(0, min(680, geometry.size.width - 48)), alignment: .leading)
                    .padding(.horizontal, Space.s24)
                    .padding(.top, Space.s24).padding(.bottom, Space.s32)
                    .frame(maxWidth: .infinity)
            }
        }.background { PageBackground(atmosphere: mainAtmosphere) }
    }
}

struct AnimatedMoney: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double?
    var placeholder = "—"
    var font: Font? = nil
    var showPlus = false
    var body: some View {
        Text(value.map { (showPlus && $0 >= 0 ? "+" : "") + Format.money($0) } ?? placeholder)
            .font(font ?? theme.label).monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value ?? 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
    }
}

struct AnimatedPercent: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Percent points: 1.5 means +1.50%.
    let value: Double
    var suffix = ""
    var font: Font? = nil
    var body: some View {
        Text(String(format: "%+.2f%%", value) + suffix)
            .font(font ?? theme.meta).monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
    }
}

struct FeatureLink<Destination: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var detail = ""
    @ViewBuilder var destination: Destination
    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: Space.s12) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(title).font(theme.label)
                    if !detail.isEmpty { Text(detail).font(theme.meta).foregroundStyle(theme.muted) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(theme.meta).foregroundStyle(theme.muted)
            }.foregroundStyle(theme.ink).padding(.vertical, Space.s8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct InputField: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content.padding(Space.s12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Space.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: Space.smallRadius).stroke(theme.line))
    }
}

/// Transient, non-blocking message (order fills, background events). Blocking alerts are only for user actions.
struct ToastView: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text).font(theme.label).foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s16).padding(.vertical, Space.s12)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().stroke(theme.line))
            .padding(.horizontal, Space.s24)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Platform shims (iOS-only modifiers become no-ops on macOS)

enum CapitalizationMode { case words, characters, never }
enum NumberKeyboard { case whole, decimal }

extension View {
    func inputField() -> some View { modifier(InputField()) }

    @ViewBuilder func appCapitalization(_ mode: CapitalizationMode) -> some View {
        #if os(iOS)
        switch mode {
        case .words: self.textInputAutocapitalization(.words)
        case .characters: self.textInputAutocapitalization(.characters)
        case .never: self.textInputAutocapitalization(.never)
        }
        #else
        self
        #endif
    }
    @ViewBuilder func appNumberKeyboard(_ kind: NumberKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .whole: self.keyboardType(.numberPad)
        case .decimal: self.keyboardType(.decimalPad)
        }
        #else
        self
        #endif
    }
    @ViewBuilder func appStockCover<Item: Identifiable, Presented: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Presented) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
    @ViewBuilder func appInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func appHideRootBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

/// Parses user-typed amounts in the user's locale ("1.234,56" in de_DE) into Decimal.
enum DecimalInput {
    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "")
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        if let number = formatter.number(from: trimmed) as? NSDecimalNumber { return number.decimalValue }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }
    static func positive(_ text: String) -> Decimal? {
        guard let value = parse(text), value > 0 else { return nil }
        return value
    }
}
