import Foundation

/// Real-money details for a ticket that sends orders to Alpaca instead of the simulator.
struct LiveTicketInfo {
    let environment: BrokerEnvironment
    let buyingPower: Decimal?
    let equity: Decimal?
    /// Signed shares currently held at the broker.
    let heldShares: Decimal
}

/// What a ticket needs to validate and preview an order. Practice, replay and real money supply different ones.
struct TicketContext {
    let symbol: String
    let kind: SecurityKind
    let quote: Quote?
    let account: AccountData
    let market: MarketContext
    /// Average true range on the chart's timeframe, for stop presets.
    let atr: Double?
    var isReplay = false
    /// Tools the learner hasn't unlocked yet.
    var locked: Set<LabFeature> = []
    /// Beginner coaching for the order as it's being built.
    var coach: ((OrderRequest, Decimal?) -> [CoachNote])? = nil
    var coolDownUntil: Date? = nil
    var live: LiveTicketInfo? = nil
}
