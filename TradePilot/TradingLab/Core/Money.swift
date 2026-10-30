import Foundation

// Money and quantities are Decimal end to end. Feeds deliver Double; convert once, at the edge.
nonisolated enum Precision {
    static let cash = 2
    static let shares = 6
    static let price = 4
}

nonisolated extension Decimal {
    func rounded(_ scale: Int, _ mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, mode)
        return result
    }
    /// Price from a feed Double, trimmed of binary noise (0.30000000000000004 → 0.3).
    static func price(_ value: Double) -> Decimal { Decimal(value).rounded(Precision.price) }
    static func cash(_ value: Double) -> Decimal { Decimal(value).rounded(Precision.cash) }
    /// Rounds to the exchange tick: cents at or above $1, hundredths of a cent below.
    var tickRounded: Decimal { rounded(self >= 1 ? 2 : Precision.price) }
    static func shares(_ value: Double) -> Decimal { Decimal(value).rounded(Precision.shares, .down) }
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
    var isPositive: Bool { self > 0 }
    /// Notional of a fill, settled to the cent.
    static func notional(_ shares: Decimal, _ price: Decimal) -> Decimal { (shares * price).rounded(Precision.cash) }
}

nonisolated enum Format {
    static func money(_ value: Decimal) -> String { value.formatted(.currency(code: "USD")) }
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    static func signedMoney(_ value: Decimal) -> String { (value >= 0 ? "+" : "") + money(value) }
    static func signedMoney(_ value: Double) -> String { (value >= 0 ? "+" : "") + money(value) }
    static func shares(_ value: Decimal) -> String { value.formatted(.number.precision(.fractionLength(0...6))) }
    /// Plain number for prices in labels: "101.5", "0.0123". Empty for nil.
    static func plain(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
    static func price(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 1 ? 4 : 2)).grouping(.never))
    }
    static func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
    static func percent(_ fraction: Double, digits: Int = 2) -> String {
        String(format: "%+.\(digits)f%%", fraction * 100)
    }
}
