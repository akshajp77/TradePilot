import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// Interface grammar: 4/8/12/16/24/32 spacing, 4/10 radii, flat rows, hairline separators,
// one outlined grouping surface, no decorative shadows. SF Symbols only.

enum Space {
    static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12
    static let s16: CGFloat = 16, s24: CGFloat = 24, s32: CGFloat = 32
    static let radius: CGFloat = 10, smallRadius: CGFloat = 4
}

enum AppTheme: String, CaseIterable, Identifiable {
    case botanical = "Botanical", ethereal = "Ethereal blue", grayscale = "Grayscale", darkGrayscale = "Dark grayscale"
    var id: String { rawValue }
    var forcedScheme: ColorScheme? { self == .grayscale ? .light : self == .darkGrayscale ? .dark : nil }
}

enum PreferenceKeys {
    static let theme = "lab-theme"
    static let appearance = "lab-appearance"
    static let largerText = "lab-larger-text"
    static let accessibleColors = "lab-accessible-colors"
    static let quoteMetric = "lab-quote-metric"
    static let showFullPositions = "trading-lab-show-full-positions"
    static let narratorVoice = "lab-narrator-voice"
}

private func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    #if os(iOS)
    return Color(uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #else
    return Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
    #endif
}

struct Palette: Equatable {
    var ink: Color
    var muted: Color
    var paper: Color
    var surface: Color
    var line: Color
    var accent: Color
    var buttonFill: Color
    /// Portfolio and account gains (follows the theme).
    var green: Color
    var loss: Color
}

/// Resolved once per preference change and injected through the environment.
/// Reading a color or font is a stored-property access, not a UserDefaults lookup.
struct Theme: Equatable {
    var kind: AppTheme
    var isLearning = false
    private var main: Palette
    private var learn: Palette
    private var palette: Palette { isLearning ? learn : main }

    var ink: Color { palette.ink }
    var muted: Color { palette.muted }
    var paper: Color { palette.paper }
    var surface: Color { palette.surface }
    var line: Color { palette.line }
    var accent: Color { palette.accent }
    var buttonFill: Color { palette.buttonFill }
    var green: Color { palette.green }
    var loss: Color { palette.loss }

    /// Stock movement colors (always green/red, or blue/orange when accessible colors are on).
    let stockGain: Color
    let stockLoss: Color
    let warning: Color
    let disabled: Color
    let orange: Color
    let teal: Color

    let display: Font
    let page: Font
    let section: Font
    let body: Font
    let label: Font
    let meta: Font

    init(kind: AppTheme, accessibleColors: Bool, largerText: Bool) {
        self.kind = kind
        let scale: CGFloat = largerText ? 1.2 : 1
        func type(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size * scale, weight: weight) }
        display = type(39, .regular); page = type(30, .regular); section = type(21, .medium)
        body = type(16, .regular); label = type(14, .medium); meta = type(12, .regular)

        let gain = accessibleColors ? adaptive((0.13, 0.37, 0.67), (0.38, 0.67, 0.95)) : adaptive((0.08, 0.55, 0.25), (0.20, 0.82, 0.38))
        let drop = accessibleColors ? adaptive((0.69, 0.36, 0.08), (0.94, 0.62, 0.31)) : adaptive((0.82, 0.17, 0.20), (1, 0.28, 0.25))
        stockGain = gain
        stockLoss = drop
        warning = adaptive((0.66, 0.43, 0.14), (0.86, 0.65, 0.34))
        disabled = adaptive((0.72, 0.74, 0.70), (0.37, 0.42, 0.38))
        orange = adaptive((0.76, 0.36, 0.08), (1, 0.66, 0.33))
        teal = adaptive((0.04, 0.49, 0.47), (0.28, 0.80, 0.74))

        switch kind {
        case .botanical:
            main = Palette(ink: adaptive((0.11, 0.15, 0.14), (0.90, 0.93, 0.90)), muted: adaptive((0.40, 0.44, 0.42), (0.62, 0.68, 0.64)),
                           paper: adaptive((0.985, 0.984, 0.975), (0.08, 0.11, 0.10)), surface: adaptive((1, 1, 1), (0.12, 0.16, 0.14)),
                           line: adaptive((0.84, 0.86, 0.82), (0.25, 0.31, 0.27)), accent: adaptive((0.13, 0.31, 0.26), (0.57, 0.79, 0.65)),
                           buttonFill: Color(red: 0.13, green: 0.31, blue: 0.26), green: gain, loss: drop)
        case .ethereal:
            main = Palette(ink: adaptive((0.10, 0.16, 0.28), (0.90, 0.94, 1)), muted: adaptive((0.44, 0.47, 0.52), (0.64, 0.67, 0.72)),
                           paper: adaptive((0.965, 0.977, 1), (0.055, 0.075, 0.12)), surface: adaptive((1, 1, 1), (0.10, 0.13, 0.20)),
                           line: adaptive((0.84, 0.86, 0.89), (0.25, 0.27, 0.31)), accent: adaptive((0.18, 0.39, 0.75), (0.50, 0.71, 1)),
                           buttonFill: Color(red: 0.18, green: 0.39, blue: 0.75), green: adaptive((0.18, 0.41, 0.78), (0.47, 0.69, 1)), loss: drop)
        case .grayscale, .darkGrayscale:
            let ink = adaptive((0.10, 0.10, 0.11), (0.94, 0.94, 0.95))
            main = Palette(ink: ink, muted: adaptive((0.44, 0.47, 0.52), (0.64, 0.67, 0.72)),
                           paper: adaptive((0.985, 0.985, 0.985), (0.06, 0.06, 0.065)), surface: adaptive((1, 1, 1), (0.12, 0.12, 0.13)),
                           line: adaptive((0.84, 0.86, 0.89), (0.25, 0.27, 0.31)), accent: adaptive((0.22, 0.23, 0.25), (0.79, 0.80, 0.83)),
                           buttonFill: Color(red: 0.22, green: 0.23, blue: 0.25), green: ink, loss: ink)
        }
        let learnAccent = adaptive((0.16, 0.38, 0.78), (0.47, 0.69, 1))
        learn = Palette(ink: adaptive((0.10, 0.16, 0.28), (0.90, 0.94, 1)), muted: adaptive((0.40, 0.46, 0.56), (0.64, 0.70, 0.79)),
                        paper: adaptive((0.965, 0.977, 1), (0.055, 0.075, 0.12)), surface: adaptive((1, 1, 1), (0.10, 0.13, 0.20)),
                        line: adaptive((0.82, 0.87, 0.94), (0.22, 0.29, 0.40)), accent: learnAccent,
                        buttonFill: Color(red: 0.16, green: 0.38, blue: 0.78), green: learnAccent,
                        loss: adaptive((0.78, 0.19, 0.26), (1, 0.43, 0.49)))
    }

    /// The Learn palette. A flag flip, so it is cheap to read from any view.
    var learning: Theme {
        var t = self
        t.isLearning = true
        return t
    }

    func gain(_ positive: Bool) -> Color { positive ? green : loss }
    func movement(_ positive: Bool) -> Color { positive ? stockGain : stockLoss }

    static let standard = Theme(kind: .botanical, accessibleColors: false, largerText: false)
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.standard }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Switches a subtree to the Learn palette.
    func learningTheme() -> some View { modifier(LearningThemeModifier()) }
}

private struct LearningThemeModifier: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        let learning = theme.learning
        content.environment(\.theme, learning).foregroundStyle(learning.ink).tint(learning.accent)
    }
}
