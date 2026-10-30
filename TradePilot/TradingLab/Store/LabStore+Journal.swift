import Foundation

// MARK: - Journal export

extension LabStore {
    var csvJournal: String {
        func quoted(_ value: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(String(value.prefix(1))) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = "Date,Symbol,Side,Shares,Type,Role,Status,Limit,Stop,Fill price,Filled at,Fees,Strategy,Confidence,Emotion,Followed plan,Thesis,Invalidation,Horizon,Reflection"
        let iso = ISO8601DateFormatter()
        let rows = data.orders.map { order -> String in
            let note = features.tradeNotes[order.id.uuidString] ?? TradeNote()
            let values = [iso.string(from: order.submittedAt), order.symbol, order.side.rawValue, "\(order.shares)", order.type.rawValue,
                          order.role.rawValue, order.status.rawValue, Format.plain(order.limit), Format.plain(order.stop), Format.plain(order.fillPrice),
                          order.filledAt.map(iso.string(from:)) ?? "", "\(order.fees)",
                          note.strategy, String(note.confidence), note.emotion,
                          note.followedPlan.map { $0 ? "Yes" : "No" } ?? "", order.thesis, order.invalidation, order.horizon, order.reflection]
            return values.map(quoted).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    var tradesCSV: String {
        let header = "Symbol,Side,Entry time,Exit time,Quantity,Avg entry,Avg exit,Gross P&L,Fees,Net P&L,R,Setup"
        let iso = ISO8601DateFormatter()
        let rows = roundTrips.filter { !$0.isOpen }.map { t in
            [t.symbol, t.isLong ? "Long" : "Short", iso.string(from: t.entryTime), t.exitTime.map(iso.string(from:)) ?? "",
             "\(t.quantity)", Format.plain(t.averageEntry), Format.plain(t.averageExit), "\(t.grossPnL)", "\(t.fees)", "\(t.netPnL)",
             t.rMultiple.map { String(format: "%.2f", $0) } ?? "", t.setup].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    var journalReport: String {
        "Trading Lab · \(activeTitle)\nExported \(Date().formatted())\n\n" + data.orders.map { order in
            "\(order.submittedAt.formatted()) · \(order.summary) · \(order.status.rawValue)\nPlan: \(order.thesis)\nChange my mind if: \(order.invalidation)\nHorizon: \(order.horizon)\nReflection: \(order.reflection)\n"
        }.joined(separator: "\n")
    }
}
