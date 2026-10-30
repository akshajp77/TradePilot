import XCTest
#if canImport(TradingLabCore)
@testable import TradingLabCore
#else
@testable import TradingLab // Rename to your app's module name if it differs.
#endif

private func et(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/New_York")
    formatter.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}
private func d(_ s: String) -> Decimal { Decimal(string: s)! }
private func fill(_ symbol: String, _ side: OrderSide, _ shares: Decimal, at price: Decimal, _ when: String, fees: Decimal = 0) -> PracticeOrder {
    PracticeOrder(symbol: symbol, side: side, shares: shares, type: .market, submittedAt: et(when),
                  status: .filled, fillPrice: price, filledAt: et(when), fees: fees)
}
private func account(_ balance: Decimal, _ configure: (inout TradingSettings) -> Void = { _ in }) -> AccountData {
    var a = AccountData(initialBalance: balance)
    configure(&a.settings)
    return a
}
private func ideal(_ s: inout TradingSettings) { s.fillModel = .ideal }
private func context(_ now: String, prices: [String: Decimal] = [:], dayPnL: Decimal? = nil) -> MarketContext {
    MarketContext(price: { prices[$0] }, dayPnL: dayPnL, now: et(now))
}
private func q(_ price: Decimal, _ when: String, source: QuoteSource = .delayed, bid: Decimal? = nil, ask: Decimal? = nil) -> Quote {
    Quote(price: price, time: et(when), source: source, bid: bid, ask: ask)
}
private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error } else { return nil } }
    var value: Success? { if case .success(let v) = self { return v } else { return nil } }
}

// MARK: - Ledger

final class LedgerTests: XCTestCase {
    func testFractionalTradesKeepExactCostBasis() {
        let ledger = Ledger(initialBalance: 1_000, orders: [
            fill("AAPL", .buy, d("0.1"), at: 200, "2026-10-19 10:00"),
            fill("AAPL", .buy, d("0.2"), at: 210, "2026-10-19 11:00"),
            fill("AAPL", .sell, d("0.15"), at: 220, "2026-10-20 10:00"),
        ])
        XCTAssertEqual(ledger.shares("AAPL"), d("0.15"))
        XCTAssertEqual(ledger.costBasis("AAPL"), d("31.00"))
        XCTAssertEqual(ledger.cash, d("971.00")) // 1000 − 20 − 42 + 33
        XCTAssertEqual(ledger.realized.first?.gain, d("2.00"))
    }

    func testShortRoundTripAndFees() {
        let ledger = Ledger(initialBalance: 10_000, orders: [
            fill("TSLA", .sell, 10, at: 250, "2026-10-20 09:45", fees: 1),
            fill("TSLA", .buy, 10, at: 240, "2026-10-20 10:30", fees: 1),
        ])
        XCTAssertNil(ledger.position("TSLA"))
        XCTAssertEqual(ledger.cash, 10_098) // +2500 −1 −2400 −1
        XCTAssertEqual(ledger.realized.first?.gain, 100)
        XCTAssertEqual(ledger.realized.first?.wasShort, true)
        XCTAssertEqual(ledger.realizedNet, 99) // closing fill's fee only
        XCTAssertEqual(ledger.totalFees, 2)
    }

    func testFlipLongToShort() {
        let ledger = Ledger(initialBalance: 10_000, orders: [
            fill("AAPL", .buy, 10, at: 100, "2026-10-20 10:00"),
            fill("AAPL", .sell, 25, at: 110, "2026-10-20 11:00"),
        ])
        let position = try! XCTUnwrap(ledger.position("AAPL"))
        XCTAssertEqual(position.quantity, -15)
        XCTAssertEqual(position.averagePrice, 110)
        XCTAssertEqual(ledger.realized.first?.gain, 100)
        XCTAssertEqual(ledger.value { _ in 100 }, 10_000 + 100 + 150) // short gains $10 × 15
    }

    func testUnsettledProceedsAndDayTrades() {
        let orders = [
            fill("AAPL", .buy, 10, at: 100, "2026-10-19 10:00"),
            fill("AAPL", .sell, 10, at: 101, "2026-10-20 10:00"),   // not a day trade
            fill("MSFT", .buy, 1, at: 300, "2026-10-20 10:05"),
            fill("MSFT", .sell, 1, at: 301, "2026-10-20 10:10"),    // day trade
        ]
        let ledger = Ledger(initialBalance: 10_000, orders: orders)
        XCTAssertEqual(ledger.unsettledProceeds(asOf: et("2026-10-20 15:00")), 1_010 + 301)
        XCTAssertEqual(ledger.unsettledProceeds(asOf: et("2026-10-21 10:00")), 0)
        XCTAssertEqual(ledger.dayTradeCount(asOf: et("2026-10-20 15:00")), 1)
    }

    func testDayPnLCoversHeldBoughtAndShorted() {
        var a = AccountData(initialBalance: 10_000)
        a.orders = [
            fill("AAPL", .buy, 10, at: 100, "2026-10-19 10:00"),  // held overnight, prev close 102
            fill("AAPL", .buy, 10, at: 104, "2026-10-20 10:00"),  // bought today
            fill("TSLA", .sell, 5, at: 200, "2026-10-20 10:00"),  // shorted today
        ]
        let now = et("2026-10-20 15:00")
        XCTAssertEqual(DayPnL.symbol("AAPL", account: a, price: 105, previousClose: 102, now: now), 40) // 10×3 + 10×1
        XCTAssertEqual(DayPnL.symbol("TSLA", account: a, price: 190, previousClose: 198, now: now), 50)
        XCTAssertEqual(DayPnL.account(a, price: { ["AAPL": 105, "TSLA": 190][$0] }, previousClose: { ["AAPL": 102, "TSLA": 198][$0] }, now: now), 90)
    }

    func testDrawdown() {
        let samples = [110.0, 90.0, 120.0, 96.0].enumerated().map { PortfolioSample(date: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element) }
        XCTAssertEqual(Ledger.maxDrawdown(samples, start: 100), -0.2, accuracy: 1e-9)
    }
}

// MARK: - Margin

final class MarginTests: XCTestCase {
    func testBuyingPowerByAccountType() {
        var margin = account(10_000)
        margin.orders = [fill("AAPL", .buy, 50, at: 100, "2026-10-20 10:00")]
        let m = Margin.snapshot(account: margin, ledger: Ledger(margin), price: { _ in 100 }, now: et("2026-10-20 11:00"))!
        XCTAssertEqual(m.equity, 10_000)
        XCTAssertEqual(m.buyingPower, 15_000) // (10,000 − 50% × 5,000) / 50%
        XCTAssertEqual(m.maintenanceRequirement, 1_500)

        var cash = account(10_000) { $0.accountType = .cash }
        cash.orders = [fill("AAPL", .buy, 50, at: 100, "2026-10-20 10:00"), fill("AAPL", .sell, 10, at: 100, "2026-10-20 10:30")]
        let c = Margin.snapshot(account: cash, ledger: Ledger(cash), price: { _ in 100 }, now: et("2026-10-20 11:00"))!
        XCTAssertEqual(c.buyingPower, 5_000, "sale proceeds settle T+1")

        let small = account(1_500)
        let s = Margin.snapshot(account: small, ledger: Ledger(small), price: { _ in 100 }, now: et("2026-10-20 11:00"))!
        XCTAssertFalse(s.leverage)
        XCTAssertEqual(s.buyingPower, 1_500)
    }
}

// MARK: - Order engine

final class OrderEngineTests: XCTestCase {
    func submit(_ a: inout AccountData, _ r: OrderRequest, quote: Quote?, at now: String, dayPnL: Decimal? = nil) -> Result<PracticeOrder, OrderRejection> {
        OrderEngine.submit(r, kind: .stock, account: &a, quote: quote, context: context(now, prices: quote.map { [r.symbol: $0.price] } ?? [:], dayPnL: dayPnL))
    }
    func process(_ a: inout AccountData, _ symbol: String, _ quote: Quote) -> [OrderEvent] {
        OrderEngine.process(symbol: symbol, quote: quote, account: &a, context: context("2026-10-20 12:00", prices: [symbol: quote.price]))
    }

    func testMarketFillUsesAskPlusSlippage() throws {
        var a = account(10_000)
        let order = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .market),
                               quote: q(100, "2026-10-20 10:00", source: .iexTrade, bid: d("99.98"), ask: d("100.02")), at: "2026-10-20 10:00").get()
        XCTAssertEqual(order.status, .filled)
        XCTAssertEqual(order.fillPrice, d("100.04")) // 100.02 + 2 bps
        var b = account(10_000, ideal)
        let idealOrder = try submit(&b, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .market),
                                    quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:05").get()
        XCTAssertEqual(idealOrder.fillPrice, 100)
    }

    func testMarketOrderAfterHoursQueuesThenFillsAtNextOpen() throws {
        var a = account(10_000, ideal)
        let order = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .market),
                               quote: q(100, "2026-10-23 16:00"), at: "2026-10-24 11:00").get()
        XCTAssertEqual(order.status, .queued)
        XCTAssertEqual(order.expiresAt, et("2026-10-26 16:00"))
        XCTAssertTrue(process(&a, "AAPL", q(99, "2026-10-26 08:00")).isEmpty, "pre-market prints don't fill market orders")
        let events = process(&a, "AAPL", q(102, "2026-10-26 09:31"))
        XCTAssertEqual(events.first?.order.fillPrice, 102)
        XCTAssertEqual(Ledger(a).cash, 8_980)
    }

    func testQueuedBuyCanceledWhenGapExceedsBuyingPower() throws {
        var a = account(1_000) { $0.accountType = .cash; $0.fillModel = .ideal }
        _ = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .market), quote: q(100, "2026-10-23 16:00"), at: "2026-10-24 11:00").get()
        let events = process(&a, "AAPL", q(120, "2026-10-26 09:31"))
        guard case .canceled = events.first else { return XCTFail("expected cancel") }
        XCTAssertEqual(Ledger(a).cash, 1_000)
    }

    func testLimitBuyWaitsThenFillsAtLimitOrBetter() throws {
        var a = account(10_000)
        let order = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .limit, limit: 95),
                               quote: q(100, "2026-10-20 10:00", source: .iexTrade), at: "2026-10-20 10:00").get()
        XCTAssertEqual(order.status, .open)
        XCTAssertTrue(process(&a, "AAPL", q(96, "2026-10-20 10:30")).isEmpty)
        let events = process(&a, "AAPL", q(d("94.5"), "2026-10-20 11:00"))
        XCTAssertEqual(events.first?.order.fillPrice, d("94.51"), "buys at the synthetic ask, never above the limit")
    }

    func testStopValidationTriggerAndGap() throws {
        var a = account(10_000, ideal)
        if case .stopOnWrongSide = submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .stop, stop: 99), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure {} else { XCTFail("buy stop below market must be rejected") }
        let order = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .stop, stop: 101), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        XCTAssertEqual(order.status, .open)
        XCTAssertTrue(process(&a, "AAPL", q(d("100.5"), "2026-10-20 10:10")).isEmpty)
        let events = process(&a, "AAPL", q(103, "2026-10-20 10:20"))
        XCTAssertEqual(events.map { if case .triggered = $0 { return "t" } else if case .filled = $0 { return "f" } else { return "?" } }, ["t", "f"])
        XCTAssertEqual(events.last?.order.fillPrice, 103, "gapped through the stop: fills at the market")
    }

    func testStopLimitDoesNotChase() throws {
        var a = account(10_000, ideal)
        _ = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .stopLimit, limit: d("101.5"), stop: 101),
                       quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        let events = process(&a, "AAPL", q(103, "2026-10-20 10:20"))
        XCTAssertEqual(events.count, 1, "triggered but above the limit: no fill")
        let fill = process(&a, "AAPL", q(d("101.2"), "2026-10-20 10:21"))
        XCTAssertEqual(fill.first?.order.fillPrice, d("101.2"))
    }

    func testTrailingStopFollowsHighs() throws {
        var a = account(10_000, ideal)
        a.orders = [fill("AAPL", .buy, 10, at: 100, "2026-10-20 09:45")]
        _ = try submit(&a, OrderRequest(symbol: "AAPL", side: .sell, shares: 10, type: .trailingStop, trailAmount: 2),
                       quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        XCTAssertTrue(process(&a, "AAPL", q(105, "2026-10-20 10:10")).isEmpty) // anchor 105, stop 103
        XCTAssertTrue(process(&a, "AAPL", q(d("103.5"), "2026-10-20 10:11")).isEmpty)
        let events = process(&a, "AAPL", q(d("102.9"), "2026-10-20 10:12"))
        XCTAssertEqual(events.last?.order.fillPrice, d("102.9"))
        XCTAssertEqual(Ledger(a).shares("AAPL"), 0)
    }

    func testBracketHeldUntilEntryThenOCO() throws {
        var a = account(10_000, ideal)
        var request = OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .limit, limit: 99)
        request.takeProfit = 105; request.stopLoss = 97
        let entry = try submit(&a, request, quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        XCTAssertEqual(entry.plannedStop, 97)
        XCTAssertEqual(a.orders.filter { $0.status == .held }.count, 2)
        XCTAssertTrue(process(&a, "AAPL", q(98, "2026-10-20 09:59")).isEmpty, "prints before submission are ignored")
        let filled = process(&a, "AAPL", q(d("98.5"), "2026-10-20 10:05"))
        XCTAssertEqual(filled.filter { if case .activated = $0 { return true } else { return false } }.count, 2)
        let exit = process(&a, "AAPL", q(106, "2026-10-20 11:00"))
        XCTAssertEqual(exit.first?.order.role, .takeProfit)
        XCTAssertEqual(a.orders.first { $0.role == .stopLoss }?.status, .canceled)
        XCTAssertEqual(Ledger(a).realized.first?.gain, 75) // (106 − 98.5) × 10
    }

    func testCancelingParentCancelsLegs() throws {
        var a = account(10_000, ideal)
        var request = OrderRequest(symbol: "AAPL", side: .buy, shares: 10, type: .limit, limit: 99)
        request.stopLoss = 97
        let entry = try submit(&a, request, quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        XCTAssertTrue(OrderEngine.cancel(entry.id, account: &a))
        XCTAssertTrue(a.orders.allSatisfy { $0.status == .canceled })
    }

    func testExitsCancelWhenPositionClosedManually() throws {
        var a = account(10_000, ideal)
        a.orders = [fill("AAPL", .buy, 10, at: 100, "2026-10-20 09:45")]
        var stop = OrderRequest(symbol: "AAPL", side: .sell, shares: 10, type: .stop, stop: 95)
        stop.reduceOnly = true
        _ = try submit(&a, stop, quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        _ = try submit(&a, OrderRequest(symbol: "AAPL", side: .sell, shares: 10, type: .market), quote: q(101, "2026-10-20 10:05"), at: "2026-10-20 10:05").get()
        XCTAssertEqual(a.orders.first { $0.type == .stop }?.status, .canceled)
    }

    func testExtendedHoursLimitsOnly() throws {
        var a = account(10_000, ideal)
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market, extendedHours: true),
                              quote: q(100, "2026-10-20 08:00"), at: "2026-10-20 08:00").failure, .extendedHoursNeedsLimit)
        let order = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .limit, limit: 101, extendedHours: true),
                               quote: q(100, "2026-10-20 08:00"), at: "2026-10-20 08:00").get()
        XCTAssertEqual(order.status, .filled, "marketable limit fills in pre-market")
        let plain = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .limit, limit: 101),
                               quote: q(100, "2026-10-20 08:01"), at: "2026-10-20 08:01").get()
        XCTAssertEqual(plain.status, .open, "regular-hours limit waits for the open")
    }

    func testDayOrdersExpire() throws {
        var a = account(10_000, ideal)
        _ = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .limit, limit: 90), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        var gtc = OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .limit, limit: 80); gtc.tif = .gtc
        _ = try submit(&a, gtc, quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        let events = OrderEngine.expire(account: &a, now: et("2026-10-20 16:01"))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(a.orders.filter { $0.status == .open }.count, 1)
    }

    func testShortingRules() {
        var cash = account(10_000) { $0.accountType = .cash }
        XCTAssertEqual(submit(&cash, OrderRequest(symbol: "AAPL", side: .sell, shares: 1, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure,
                       .insufficientShares(available: 0))
        var small = account(1_500)
        if case .shortingNotAllowed = submit(&small, OrderRequest(symbol: "AAPL", side: .sell, shares: 1, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure {} else { XCTFail() }
        var margin = account(10_000, ideal)
        let short = submit(&margin, OrderRequest(symbol: "AAPL", side: .sell, shares: 10, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00")
        XCTAssertEqual(short.value?.status, .filled)
        XCTAssertEqual(Ledger(margin).shares("AAPL"), -10)
    }

    func testBuyingPowerAndIntradayMargin() {
        var a = account(10_000, ideal)
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 201, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure,
                       .insufficientBuyingPower(available: 20_000))
        var strict = account(10_000) { $0.fillModel = .ideal; $0.maintenanceRate = d("0.6") }
        if case .marginDeficit = submit(&strict, OrderRequest(symbol: "AAPL", side: .buy, shares: 190, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure {} else { XCTFail("expected deficit") }
    }

    func testLegacyPDTProtection() throws {
        var a = account(10_000) { $0.regime = .legacyPDT; $0.fillModel = .ideal }
        a.orders = [
            fill("A", .buy, 1, at: 10, "2026-10-19 10:00"), fill("A", .sell, 1, at: 10, "2026-10-19 10:01"),
            fill("B", .buy, 1, at: 10, "2026-10-19 10:00"), fill("B", .sell, 1, at: 10, "2026-10-19 10:01"),
            fill("C", .buy, 1, at: 10, "2026-10-20 10:00"), fill("C", .sell, 1, at: 10, "2026-10-20 10:01"),
            fill("AAPL", .buy, 1, at: 100, "2026-10-20 11:00"),
        ]
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .sell, shares: 1, type: .market), quote: q(100, "2026-10-20 12:00"), at: "2026-10-20 12:00").failure,
                       .pdtProtection(dayTrades: 3))
        a.settings.regime = .intraday2026
        XCTAssertNotNil(submit(&a, OrderRequest(symbol: "AAPL", side: .sell, shares: 1, type: .market), quote: q(100, "2026-10-20 12:00"), at: "2026-10-20 12:00").value)
    }

    func testRiskGuardrails() {
        var a = account(10_000) { $0.fillModel = .ideal; $0.dailyLossLimit = 500; $0.maxPositionFraction = d("0.25") }
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00", dayPnL: -500).failure,
                       .dailyLossLimit(500))
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 26, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure,
                       .positionTooLarge(d("0.25")))
        a.settings.requireStop = true
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").failure, .stopRequired)
        var withStop = OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market); withStop.stopLoss = 98
        XCTAssertNotNil(submit(&a, withStop, quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").value)
    }

    func testRejectionsAndSizing() {
        var a = account(100)
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: d("0.0000001"), type: .market), quote: q(1, "2026-10-20 10:00"), at: "2026-10-20 10:01").failure, .invalidQuantity)
        XCTAssertEqual(submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market), quote: q(1, "2026-10-01 10:00"), at: "2026-10-20 10:01").failure, .noPrice)
        XCTAssertEqual(OrderEngine.submit(OrderRequest(symbol: "^GSPC", side: .buy, shares: 1, type: .market), kind: .index, account: &a,
                                          quote: q(1, "2026-10-20 10:00"), context: context("2026-10-20 10:01")).failure, .notTradable)
        XCTAssertTrue(a.orders.isEmpty)
        XCTAssertEqual(OrderEngine.shares(risking: 100, entry: 50, stop: 48, fractional: false), 50)
    }

    func testModifyMovesWorkingOrder() throws {
        var a = account(10_000, ideal)
        let order = try submit(&a, OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .limit, limit: 90), quote: q(100, "2026-10-20 10:00"), at: "2026-10-20 10:00").get()
        XCTAssertTrue(OrderEngine.modify(order.id, limit: d("92.5"), account: &a))
        XCTAssertEqual(a.orders.first?.limit, d("92.5"))
        XCTAssertFalse(OrderEngine.modify(order.id, stop: 80, account: &a), "limits have no stop")
    }
}

// MARK: - Legacy data

final class LegacyDecodingTests: XCTestCase {
    func testV1AccountWithDoubleNoiseAndWrongBaseline() throws {
        let json = """
        {"initialBalance":100000,"name":"Sam","cash":9989.999999999998,"holdings":{"AAPL":0.30000000000000004},
         "orders":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","symbol":"AAPL","side":"Buy","shares":0.30000000000000004,
         "type":"Market","submittedAt":782000000,"status":"Filled","fillPrice":33.333333333333336,"filledAt":782000000,
         "thesis":"t","invalidation":"i","horizon":"h","reflection":""}],"onboardingComplete":true}
        """
        let account = try JSONDecoder().decode(AccountData.self, from: Data(json.utf8))
        XCTAssertEqual(account.orders[0].shares, d("0.3"))
        XCTAssertEqual(account.orders[0].tif, .gtc)
        XCTAssertEqual(account.initialBalance, 10_000)
        XCTAssertEqual(account.settings, TradingSettings())
        XCTAssertNotNil(Ledger(account).costBasis("AAPL"))
    }

    func testV2AlertsAndRoundTrip() throws {
        let alert = try JSONDecoder().decode(PriceAlert.self, from: Data(#"{"id":"x","symbol":"AAPL","target":190.5,"above":false}"#.utf8))
        XCTAssertEqual(alert.condition, .priceBelow(d("190.5")))
        var workspace = Workspace.fresh(name: "Ana")
        workspace.features.alerts = [alert]
        workspace.features.drawings = [ChartDrawing(symbol: "AAPL", kind: .trend(ChartPoint(time: et("2026-10-20 10:00"), price: 1), ChartPoint(time: et("2026-10-20 11:00"), price: 2)))]
        workspace.portfolios[0].account.settings.accountType = .cash
        workspace.portfolios[0].account.orders = [fill("AAPL", .buy, d("0.123456"), at: d("187.1234"), "2026-10-20 10:00")]
        let decoded = try WorkspaceCodec.decode(WorkspaceCodec.encode(workspace))
        XCTAssertEqual(decoded.portfolios[0].account.orders, workspace.portfolios[0].account.orders)
        XCTAssertEqual(decoded.features, workspace.features)
        XCTAssertEqual(decoded.portfolios[0].account.settings.accountType, .cash)
    }

    func testMigrationFromUserDefaults() throws {
        let suite = "trading-lab-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"initialBalance":100000,"name":"Jo","cash":100000,"holdings":{},"orders":[],"watched":["SPY"],"onboardingComplete":true}"#.utf8),
                     forKey: LegacyMigration.accountKey)
        defaults.set(Data(#"{"portfolios":[],"activePortfolio":"primary","tradeNotes":{"gone":{"strategy":"Value","confidence":3,"emotion":"Neutral","chart":[]}},"todaySections":["Watchlists","Events"]}"#.utf8),
                     forKey: LegacyMigration.featureKey)
        let workspace = try XCTUnwrap(LegacyMigration.migrate(from: defaults))
        XCTAssertEqual(workspace.portfolios[0].account.name, "Jo")
        XCTAssertTrue(workspace.features.tradeNotes.isEmpty)
        XCTAssertEqual(workspace.features.todaySections, [.watchlists, .events])
        LegacyMigration.markDone(defaults)
        XCTAssertNil(LegacyMigration.migrate(from: defaults))
    }
}

// MARK: - Market hours

final class MarketHoursTests: XCTestCase {
    let hours = MarketHours.nyse

    func testSessionsAndKinds() {
        XCTAssertTrue(hours.isOpen(at: et("2026-10-20 10:00")))
        XCTAssertFalse(hours.isOpen(at: et("2026-10-20 16:00")))
        XCTAssertTrue(hours.isRegularSessionPrint(et("2026-10-20 16:00")))
        XCTAssertEqual(hours.sessionKind(at: et("2026-10-20 03:59")), .closed)
        XCTAssertEqual(hours.sessionKind(at: et("2026-10-20 04:00")), .pre)
        XCTAssertEqual(hours.sessionKind(at: et("2026-10-20 18:00")), .post)
        XCTAssertEqual(hours.sessionKind(at: et("2026-11-27 16:30")), .post, "early close: after-hours runs 13:00–17:00")
        XCTAssertEqual(hours.sessionKind(at: et("2026-11-27 17:30")), .closed)
        XCTAssertEqual(hours.sessionKind(at: et("2026-10-24 12:00")), .closed)
    }

    func testHolidaysExpiryAndSessionDays() {
        XCTAssertNil(hours.session(on: et("2026-11-26 12:00")))
        XCTAssertEqual(hours.nextOpen(after: et("2026-11-25 17:00")), et("2026-11-27 09:30"))
        XCTAssertEqual(hours.dayOrderExpiry(placedAt: et("2026-10-20 10:00"), extendedHours: false), et("2026-10-20 16:00"))
        XCTAssertEqual(hours.dayOrderExpiry(placedAt: et("2026-10-20 17:00"), extendedHours: false), et("2026-10-21 16:00"))
        XCTAssertEqual(hours.dayOrderExpiry(placedAt: et("2026-10-20 17:00"), extendedHours: true), et("2026-10-20 20:00"))
        XCTAssertEqual(hours.sessionDays(endingAt: et("2026-10-26 12:00"), count: 3), [et("2026-10-26 00:00"), et("2026-10-23 00:00"), et("2026-10-22 00:00")])
    }

    func testOpenTracksDaylightSaving() {
        XCTAssertEqual(hours.session(on: et("2026-10-30 12:00"))?.open.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400), 13.5 * 3600)
        XCTAssertEqual(hours.session(on: et("2026-11-02 12:00"))?.open.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400), 14.5 * 3600)
    }
}

// MARK: - Bars, indicators, chart math

final class BarTests: XCTestCase {
    func testBuckets() {
        XCTAssertEqual(Timeframe.m5.bucketStart(for: et("2026-10-20 10:07")), et("2026-10-20 10:05"))
        XCTAssertEqual(Timeframe.h1.bucketStart(for: et("2026-10-20 10:07")), et("2026-10-20 09:30"))
        XCTAssertEqual(Timeframe.h1.bucketStart(for: et("2026-10-20 10:31")), et("2026-10-20 10:30"))
        XCTAssertEqual(Timeframe.d1.bucketStart(for: et("2026-10-20 15:59")), et("2026-10-20 09:30"))
        XCTAssertEqual(Timeframe.w1.bucketStart(for: et("2026-10-22 11:00")), et("2026-10-19 09:30"))
    }

    func testAggregatorBuildsCandles() {
        var bars: [Bar] = []
        XCTAssertTrue(BarAggregator.apply(price: 100, size: 10, time: et("2026-10-20 10:00:05"), to: &bars, timeframe: .m1))
        BarAggregator.apply(price: 101, size: 5, time: et("2026-10-20 10:00:30"), to: &bars, timeframe: .m1)
        BarAggregator.apply(price: 99, size: 5, time: et("2026-10-20 10:00:50"), to: &bars, timeframe: .m1)
        XCTAssertTrue(BarAggregator.apply(price: 99.5, size: 1, time: et("2026-10-20 10:01:01"), to: &bars, timeframe: .m1))
        XCTAssertEqual(bars.first, Bar(time: et("2026-10-20 10:00"), open: 100, high: 101, low: 99, close: 99, volume: 20))
        XCTAssertFalse(BarAggregator.apply(price: 50, size: 1, time: et("2026-10-20 09:59"), to: &bars, timeframe: .m1), "late prints are ignored")
        XCTAssertEqual(bars.count, 2)
        XCTAssertFalse(BarAggregator.apply(price: 50, size: 1, time: et("2026-10-20 18:00"), to: &bars, timeframe: .d1), "daily bars ignore after-hours")
        let five = BarAggregator.resample(bars, to: .m5)
        XCTAssertEqual(five.count, 1)
        XCTAssertEqual(five[0].volume, 21)
        XCTAssertEqual(five[0].close, 99.5)
    }

    func testHeikinAshi() {
        let ha = BarAggregator.heikinAshi([Bar(time: et("2026-10-20 10:00"), open: 10, high: 12, low: 9, close: 11, volume: 1)])
        XCTAssertEqual(ha[0].close, 10.5)
        XCTAssertEqual(ha[0].open, 10.5)
    }
}

final class IndicatorTests: XCTestCase {
    func bars(_ closes: [Double], range: Double = 2) -> [Bar] {
        closes.enumerated().map { Bar(time: et("2026-10-20 10:00").addingTimeInterval(Double($0.offset) * 60), open: $0.element, high: $0.element + range / 2, low: $0.element - range / 2, close: $0.element, volume: 100) }
    }

    func testAverages() {
        XCTAssertEqual(Indicators.sma([1, 2, 3, 4, 5], 3), [nil, nil, 2, 3, 4])
        let ema = Indicators.ema((1...10).map(Double.init), 3)
        XCTAssertEqual(ema[2], 2); XCTAssertEqual(ema[3], 3); XCTAssertEqual(ema[9], 9)
    }

    func testOscillators() {
        XCTAssertEqual(Indicators.rsi((1...30).map(Double.init)).last!, 100)
        XCTAssertEqual(Indicators.rsi((1...30).reversed().map(Double.init)).last!, 0)
        let zigzag = (0..<40).map { $0 % 2 == 0 ? 10.0 : 11.0 }
        XCTAssertEqual(Indicators.rsi(zigzag).last!!, 50, accuracy: 5)
        let flat = Indicators.macd(Array(repeating: 50, count: 60))
        XCTAssertEqual(flat.macd.last!!, 0, accuracy: 1e-9)
        XCTAssertEqual(flat.signal.last!!, 0, accuracy: 1e-9)
        XCTAssertNil(flat.signal[30])
        XCTAssertNotNil(flat.signal[33])
    }

    func testBandsATRAndVWAP() {
        let b = Indicators.bollinger(Array(repeating: 5, count: 25))
        XCTAssertEqual(b.upper.last!, 5); XCTAssertEqual(b.lower.last!, 5)
        XCTAssertEqual(Indicators.atr(bars(Array(repeating: 10, count: 20))).last!, 2)
        let session = [Bar(time: et("2026-10-19 15:59"), open: 1, high: 1, low: 1, close: 1, volume: 1),
                       Bar(time: et("2026-10-20 09:30"), open: 10, high: 10, low: 10, close: 10, volume: 1),
                       Bar(time: et("2026-10-20 09:31"), open: 20, high: 20, low: 20, close: 20, volume: 3)]
        XCTAssertEqual(Indicators.vwap(session), [1, 10, 17.5], "resets each session")
    }

    func testRelativeVolume() {
        var series: [Bar] = []
        for (day, volume) in [("2026-10-16", 100.0), ("2026-10-19", 300.0), ("2026-10-20", 400.0)] {
            series.append(Bar(time: et("\(day) 09:30"), open: 1, high: 1, low: 1, close: 1, volume: volume))
            series.append(Bar(time: et("\(day) 15:00"), open: 1, high: 1, low: 1, close: 1, volume: 1_000))
        }
        XCTAssertEqual(Indicators.relativeVolume(series, at: 4)!, 2, accuracy: 1e-9) // 400 vs avg(100, 300) at 09:30
    }
}

final class ChartMathTests: XCTestCase {
    func testViewportZoomPanAndMapping() {
        var v = ChartViewport.initial(barCount: 500, visible: 100)
        XCTAssertTrue(v.isAtLatest)
        XCTAssertEqual(v.index(atX: v.x(for: 450, plotWidth: 800), plotWidth: 800), 450, accuracy: 1e-9)
        v.zoom(by: 2, anchor: 1)
        XCTAssertEqual(v.visibleBars, 50)
        v.pan(byPoints: 400, plotWidth: 800) // drag right → older bars
        XCTAssertFalse(v.isAtLatest)
        v.zoom(by: 0.0001, anchor: 0.5)
        XCTAssertEqual(v.visibleBars, 508)
        v.update(barCount: 501)
        v.scrollToLatest()
        v.update(barCount: 505)
        XCTAssertTrue(v.isAtLatest, "follows the live edge")
    }

    func testScalesAndTicks() {
        XCTAssertEqual(NiceTicks.values(low: 101.3, high: 104.9, maxCount: 4), [102, 103, 104])
        XCTAssertEqual(NiceTicks.niceStep(0.37), 0.5)
        let scale = PriceScale(low: 100, high: 110, padding: 0)
        XCTAssertEqual(scale.y(110, height: 200), 0)
        XCTAssertEqual(scale.price(atY: 100, height: 200), 105)
        let anchorBars = (0..<3).map { Bar(time: et("2026-10-20 10:00").addingTimeInterval(Double($0) * 300), open: 1, high: 1, low: 1, close: 1, volume: 1) }
        XCTAssertEqual(ChartAnchoring.index(for: et("2026-10-20 10:07:30"), in: anchorBars, timeframe: .m5)!, 1.5, accuracy: 1e-9)
        XCTAssertEqual(ChartAnchoring.time(for: 3, in: anchorBars, timeframe: .m5), et("2026-10-20 10:15"))
    }

    func testIndicatorSeries() {
        let bars = (0..<60).map { Bar(time: et("2026-10-20 09:30").addingTimeInterval(Double($0) * 60), open: 10, high: 11, low: 9, close: 10 + Double($0 % 3), volume: 100) }
        let rsi = IndicatorSeries.compute(IndicatorConfig(kind: .rsi), bars: bars)
        XCTAssertEqual(rsi.range, 0...100)
        XCTAssertEqual(rsi.levels, [30, 70])
        XCTAssertNotNil(IndicatorSeries.compute(IndicatorConfig(kind: .bollinger), bars: bars).extent(in: 30...59))
    }
}

// MARK: - Analytics, replay, scanner, alerts

final class AnalyticsTests: XCTestCase {
    func testRoundTripsWithPartialsShortsAndFlip() {
        var a = AccountData(initialBalance: 10_000)
        var entry = fill("AAPL", .buy, 10, at: 100, "2026-10-20 10:00", fees: 1)
        entry.plannedStop = 98
        a.orders = [
            entry,
            fill("AAPL", .sell, 5, at: 104, "2026-10-20 10:30"),
            fill("AAPL", .sell, 5, at: 106, "2026-10-20 11:00"),
            fill("TSLA", .sell, 2, at: 200, "2026-10-20 12:00"),
            fill("TSLA", .buy, 5, at: 210, "2026-10-20 13:00"),   // closes short at a loss, opens 3 long
        ]
        let trips = TradeAnalytics.roundTrips(a, notes: [entry.id.uuidString: TradeNote(strategy: "Breakout")])
        let aapl = trips.first { $0.symbol == "AAPL" }!
        XCTAssertEqual(aapl.grossPnL, 50)
        XCTAssertEqual(aapl.netPnL, 49)
        XCTAssertEqual(aapl.averageExit, 105)
        XCTAssertEqual(aapl.rMultiple!, 49.0 / 20.0, accuracy: 1e-9)
        XCTAssertEqual(aapl.setup, "Breakout")
        let tsla = trips.filter { $0.symbol == "TSLA" }
        XCTAssertEqual(tsla.count, 2)
        XCTAssertEqual(tsla.first { !$0.isOpen }?.netPnL, -20)
        XCTAssertEqual(tsla.first { $0.isOpen }?.isLong, true)

        let stats = TradeAnalytics.stats(trips)
        XCTAssertEqual(stats.trades, 2)
        XCTAssertEqual(stats.winRate, 0.5)
        XCTAssertEqual(stats.profitFactor!, 49.0 / 20.0, accuracy: 1e-9)
        XCTAssertEqual(stats.expectancy, d("14.5"))
        XCTAssertEqual(stats.maxDrawdown, -20)
        XCTAssertEqual(TradeAnalytics.dailyPnL(trips)[et("2026-10-20 00:00")], 29)
        XCTAssertEqual(TradeAnalytics.breakdown(trips, by: .side).map(\.key), ["Long", "Short"])
    }
}

final class ReplayTests: XCTestCase {
    func session() -> ReplaySession {
        var bars = [Bar(time: et("2026-10-19 15:55"), open: 100, high: 100, low: 100, close: 100, volume: 1)]
        let path: [(Double, Double, Double, Double)] = [(100, 101, 99, 100.5), (100.5, 103, 100, 102.5), (102.5, 102.6, 97, 97.5), (95, 96, 94, 95.5)]
        for (i, p) in path.enumerated() {
            bars.append(Bar(time: et("2026-10-20 09:30").addingTimeInterval(Double(i) * 300), open: p.0, high: p.1, low: p.2, close: p.3, volume: 1_000))
        }
        var settings = TradingSettings(); settings.fillModel = .ideal
        return ReplaySession(symbol: "XYZ", timeframe: .m5, bars: bars, day: et("2026-10-20 09:30"), startingBalance: 10_000, settings: settings)
    }

    func testStepFillsAgainstBarPathAndStopsGap() throws {
        var replay = session()
        XCTAssertEqual(replay.history.count, 1)
        XCTAssertEqual(replay.visibleBars.count, 2)
        var entry = OrderRequest(symbol: "XYZ", side: .buy, shares: 10, type: .limit, limit: 100)
        entry.stopLoss = 96
        _ = try replay.submit(entry).get()
        replay.step() // bar 2 dips to 100 → fills at limit
        XCTAssertEqual(replay.account.orders.first { $0.role == .entry }?.fillPrice, 100)
        replay.step() // bar 3 low 97: stop at 96 untouched
        let events = replay.step() // bar 4 opens 95: gap through the stop → fills at the open
        XCTAssertEqual(events.first { if case .filled = $0 { return true } else { return false } }?.order.fillPrice, 95)
        let record = replay.finish()
        XCTAssertEqual(record.netPnL, -50)
        XCTAssertEqual(record.trades, 1)
    }

    func testPathOrdering() {
        XCTAssertEqual(ReplaySession.path(Bar(time: Date(), open: 10, high: 12, low: 9, close: 11, volume: 0)), [10, 9, 12, 11])
        XCTAssertEqual(ReplaySession.path(Bar(time: Date(), open: 10, high: 12, low: 9, close: 9.5, volume: 0)), [10, 12, 9, 9.5])
    }
}

final class ScannerAlertTests: XCTestCase {
    func testYahooScreenerParseAndPresets() {
        let json = """
        {"finance":{"result":[{"quotes":[
          {"symbol":"AAA","shortName":"Alpha","regularMarketPrice":10,"regularMarketChangePercent":12.5,"regularMarketVolume":5000000,"averageDailyVolume3Month":1000000,"regularMarketOpen":10.8,"regularMarketPreviousClose":9},
          {"symbol":"BBB","shortName":"Beta","regularMarketPrice":50,"regularMarketChangePercent":-6,"regularMarketVolume":900000,"averageDailyVolume3Month":1000000,"regularMarketOpen":46,"regularMarketPreviousClose":53},
          {"symbol":"CCC","regularMarketPrice":{"raw":1.2},"regularMarketChangePercent":{"raw":30}}
        ]}]}}
        """
        let rows = ScannerParse.yahoo(Data(json.utf8))
        XCTAssertEqual(rows.map(\.symbol), ["AAA", "BBB", "CCC"])
        XCTAssertEqual(rows[0].relativeVolume, 5)
        XCTAssertEqual(rows[0].gapPercent!, 20, accuracy: 1e-9)
        XCTAssertEqual(ScanPreset.gapUp.rank(rows).map(\.symbol), ["AAA"])
        XCTAssertEqual(ScanPreset.gapDown.rank(rows).map(\.symbol), ["BBB"])
        XCTAssertEqual(ScanPreset.unusualVolume.rank(rows).map(\.symbol), ["AAA"])
        XCTAssertEqual(rows.filter(ScanFilter.dayTrading.matches).map(\.symbol), ["AAA"])
    }

    func testAlertConditions() {
        let inputs = AlertInputs(price: 101, changePercent: 3.2, vwap: 100.5, previousVWAPSide: false, rsi: 72, relativeVolume: 2.5)
        XCTAssertTrue(AlertEvaluator.isTriggered(.priceAbove(100), inputs))
        XCTAssertFalse(AlertEvaluator.isTriggered(.priceBelow(100), inputs))
        XCTAssertTrue(AlertEvaluator.isTriggered(.changeAbove(3), inputs))
        XCTAssertTrue(AlertEvaluator.isTriggered(.crossesAboveVWAP, inputs))
        XCTAssertFalse(AlertEvaluator.isTriggered(.crossesBelowVWAP, inputs))
        XCTAssertTrue(AlertEvaluator.isTriggered(.rsiAbove(70), inputs))
        XCTAssertTrue(AlertEvaluator.isTriggered(.relativeVolumeAbove(2), inputs))
        var alert = PriceAlert(symbol: "AAPL", condition: .priceAbove(1), repeats: true)
        alert.triggeredAt = et("2026-10-20 10:00")
        XCTAssertFalse(AlertEvaluator.isArmed(alert, now: et("2026-10-20 10:05")))
        XCTAssertTrue(AlertEvaluator.isArmed(alert, now: et("2026-10-20 10:20")))
    }
}

// MARK: - Merge

final class MergeTests: XCTestCase {
    func testOrdersUnionAndFinalStateWins() {
        var a = Workspace.fresh(name: "A"), b = a
        let shared = PracticeOrder(symbol: "AAPL", side: .buy, shares: 1, type: .limit, limit: 90, submittedAt: et("2026-10-20 10:00"), status: .open)
        var filled = shared
        filled.status = .filled; filled.fillPrice = 90; filled.filledAt = et("2026-10-20 11:00"); filled.updatedAt = et("2026-10-20 11:00")
        a.portfolios[0].account.orders = [shared, fill("MSFT", .buy, 1, at: 300, "2026-10-20 10:10")]
        b.portfolios[0].account.orders = [filled, fill("SPY", .buy, 1, at: 500, "2026-10-20 10:20")]
        let merged = WorkspaceMerge.merge(local: a, remote: b)
        XCTAssertEqual(Set(merged.portfolios[0].account.orders.map(\.symbol)), ["AAPL", "MSFT", "SPY"])
        XCTAssertEqual(merged.portfolios[0].account.orders.first { $0.id == shared.id }?.status, .filled)
    }

    func testNewerResetWinsWholesale() {
        var a = Workspace.fresh(), b = a
        a.portfolios[0].account.orders = [fill("AAPL", .buy, 1, at: 100, "2026-10-19 10:00")]
        b.portfolios[0].account.resetAt = et("2026-10-20 09:00")
        XCTAssertTrue(WorkspaceMerge.merge(local: a, remote: b).portfolios[0].account.orders.isEmpty)
    }

    func testTombstonesAndReAdds() {
        var a = Workspace.fresh(), b = a
        b.portfolios.append(Portfolio(id: "p2", title: "Experiment", account: AccountData()))
        a.tombstones["portfolio:p2"] = Date()
        let drawing = ChartDrawing(symbol: "AAPL", kind: .horizontal(price: 100))
        b.features.drawings = [drawing]
        a.tombstones["drawing:\(drawing.id)"] = Date()
        let merged = WorkspaceMerge.merge(local: a, remote: b)
        XCTAssertEqual(merged.portfolios.map(\.id), ["primary"])
        XCTAssertTrue(merged.features.drawings.isEmpty)

        var c = Workspace.fresh(), e = c
        c.tombstones["security:NVDA"] = et("2026-10-19 10:00")
        e.customSecurities = [Security(symbol: "NVDA", name: "NVIDIA", kind: .stock, description: "", sector: "", addedAt: et("2026-10-20 10:00"))]
        XCTAssertEqual(WorkspaceMerge.merge(local: c, remote: e).customSecurities.map(\.symbol), ["NVDA"])
    }

    func testSettingsAndWatchlistFollowNewerCopy() {
        var a = Workspace.fresh(), b = a
        a.portfolios[0].account.watched = ["SPY", "AAPL"]; a.portfolios[0].account.updatedAt = et("2026-10-20 10:00")
        b.portfolios[0].account.watched = ["SPY"]; b.portfolios[0].account.settings.dailyLossLimit = 300
        b.portfolios[0].account.updatedAt = et("2026-10-20 11:00")
        let merged = WorkspaceMerge.merge(local: a, remote: b)
        XCTAssertEqual(merged.portfolios[0].account.watched, ["SPY"])
        XCTAssertEqual(merged.portfolios[0].account.settings.dailyLossLimit, 300)
    }
}

// MARK: - Parsing and content

final class ParsingTests: XCTestCase {
    func testYahooChartBars() throws {
        let json = """
        {"chart":{"result":[{"meta":{"regularMarketPrice":101.5,"regularMarketTime":1792512000,"longName":"Apple Inc.","instrumentType":"EQUITY","currency":"USD"},
        "timestamp":[1792252800,1792339200,1792425600],
        "indicators":{"quote":[{"close":[99.0,null,100.25],"open":[98,99,100],"high":[99.5,null,101],"low":[97,null,99.5],"volume":[1000,null,2000]}]}}]}}
        """
        let payload = try XCTUnwrap(Parse.yahooChart(Data(json.utf8), symbol: "AAPL"))
        XCTAssertEqual(payload.bars.count, 2)
        XCTAssertEqual(payload.bars[1], Bar(time: Date(timeIntervalSince1970: 1792425600), open: 100, high: 101, low: 99.5, close: 100.25, volume: 2000))
        XCTAssertEqual(payload.previousClose, 99.0)
    }

    func testAlpacaStream() {
        let json = #"[{"T":"success","msg":"authenticated"},{"T":"t","S":"AAPL","p":187.25,"s":100,"t":"2026-10-20T14:30:00.123456789Z"},{"T":"q","S":"AAPL","bp":187.2,"bs":3,"ap":187.3,"as":5,"t":"2026-10-20T14:30:00Z"}]"#
        let events = Parse.alpacaStream(Data(json.utf8))
        XCTAssertEqual(events.first, .authenticated)
        guard case .trade(let symbol, let price, let size, let time) = events[1] else { return XCTFail("no trade") }
        XCTAssertEqual(symbol, "AAPL"); XCTAssertEqual(price, 187.25); XCTAssertEqual(size, 100)
        XCTAssertEqual(time.timeIntervalSince1970, 1792506600.123, accuracy: 0.001)
        guard case .quote(_, let bid, _, let ask, let askSize, _) = events[2] else { return XCTFail("no quote") }
        XCTAssertEqual(bid, 187.2); XCTAssertEqual(ask, 187.3); XCTAssertEqual(askSize, 5)
    }

    func testEarningsAndAI() {
        let earnings = Parse.earnings(Data(#"[{"date":"2026-10-30","hour":"amc","epsEstimate":1.6},{"date":"2026-07-30","hour":""}]"#.utf8))
        XCTAssertEqual(earnings.map(\.hour), [nil, "amc"])
        XCTAssertEqual(earnings.last?.date, et("2026-10-30 00:00"))
        XCTAssertNotNil(Parse.aiImpact(#"```json {"summary":"s","direction":"up","impact":"i","watch":"w","questions":["a","b","c"]} ```"#))
        XCTAssertNil(Parse.aiImpact(#"{"summary":"s","direction":"sideways","impact":"i","watch":"w","questions":[]}"#))
    }
}

final class CurriculumTests: XCTestCase {
    func testBundledLessonsDecodeAndValidate() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let content = try JSONDecoder().decode(CurriculumContent.self, from: Data(contentsOf: root.appendingPathComponent("Resources/Lessons.json")))
        XCTAssertEqual(content.problems(), [])
        XCTAssertGreaterThanOrEqual(content.lessons.count, 6)
        XCTAssertTrue(content.glossary.contains { $0.term == "Market hours" })
        XCTAssertGreaterThanOrEqual(content.glossary.count, 80)
        XCTAssertEqual(content.units.map(\.id), ["u1", "u2", "u3", "u4", "u5"])
        XCTAssertEqual(content.glossaryEntry("RVOL")?.term, "Relative volume")
        XCTAssertEqual(content.glossaryEntry("equity")?.term, "Equity")
        for feature in LabFeature.allCases { XCTAssertNotNil(content.lesson(unlocking: feature), "\(feature) needs a lesson") }
        // Lessons that coaching notes link to must exist.
        for id in ["u1-why-prices-move", "u1-bid-ask", "u2-stop-loss", "u2-position-size", "u2-emotions", "u3-volume", "u3-trends", "u4-day-trading-reality"] {
            XCTAssertNotNil(content.pathLesson(id), id)
        }
        XCTAssertEqual(content.events.count, 3)
        XCTAssertTrue(content.calendar.contains { $0.date == "2026-12-09" && $0.kind == .fomc })
    }
}

// MARK: - Learning, coaching, labs, drills, broker

private func trip(_ pnl: Decimal, stop: Decimal? = 95, entry: Decimal = 100, qty: Decimal = 10, exit: String, setup: String = "Breakout", long: Bool = true) -> RoundTrip {
    RoundTrip(id: UUID(), symbol: "AAPL", isLong: long, entryTime: et(exit).addingTimeInterval(-600), exitTime: et(exit), quantity: qty,
              averageEntry: entry, averageExit: entry + pnl / qty, grossPnL: pnl, fees: 0, fillIDs: [], plannedStop: stop, setup: setup, isOpen: false)
}

private func bars(_ closes: [Double], volume: Double = 1_000_000, start: String = "2026-03-02 09:30") -> [Bar] {
    closes.enumerated().map { i, c in
        Bar(time: et(start).addingTimeInterval(Double(i) * 300), open: c - 0.1, high: c + 0.5, low: c - 0.5, close: c, volume: volume)
    }
}

final class LearningTests: XCTestCase {
    func testLearningMergeKeepsProgressAndUnlocks() {
        var a = LearningState(); var b = LearningState()
        a.unlocked = [.shorting]; b.unlocked = [.margin]
        a.progress["l1"] = LessonProgress(startedAt: et("2026-03-02 10:00"), quizPassed: true)
        b.progress["l1"] = LessonProgress(startedAt: et("2026-03-01 10:00"), taskDone: true, completedAt: et("2026-03-03 10:00"))
        a.actions["scanner"] = et("2026-03-02 10:00"); b.actions["scanner"] = et("2026-03-04 10:00")
        let m = LearningState.merge(a, b)
        XCTAssertEqual(Set(m.unlocked ?? []), [.shorting, .margin])
        XCTAssertEqual(m.progress["l1"]?.quizPassed, true)
        XCTAssertEqual(m.progress["l1"]?.taskDone, true)
        XCTAssertEqual(m.progress["l1"]?.startedAt, et("2026-03-01 10:00"))
        XCTAssertNotNil(m.progress["l1"]?.completedAt)
        XCTAssertEqual(m.actions["scanner"], et("2026-03-04 10:00"))
        var legacy = LearningState(); legacy.unlocked = nil
        XCTAssertNil(LearningState.merge(a, legacy).unlocked, "nil (all unlocked) wins")
        XCTAssertTrue(legacy.isUnlocked(.margin))
        XCTAssertFalse(b.isUnlocked(.shorting))
    }

    func testLearningStateRoundTripsThroughWorkspace() throws {
        var w = Workspace.fresh(name: "A")
        w.features.learning.profile = LearnerProfile(birthYear: 2000, experience: .some, goals: [.dayTrading])
        w.features.learning.unlocked = []
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(back.features.learning.profile?.experience, .some)
        XCTAssertEqual(back.features.learning.unlocked, [])
        XCTAssertEqual(back.features.learning.profile?.age(now: et("2026-06-01 10:00")), 26)
        XCTAssertTrue(back.features.learning.profile?.isAdult(now: et("2026-06-01 10:00")) ?? false)
    }

    func testPathTasks() {
        var account = AccountData(initialBalance: 10_000)
        let since = et("2026-03-02 09:00")
        let learning = LearningState()
        XCTAssertFalse(PathTasks.isDone(PathTask(kind: .bracket, instruction: ""), since: since, account: account, learning: learning))
        var o = PracticeOrder(symbol: "AAPL", side: .buy, shares: 10, type: .limit, submittedAt: et("2026-03-02 10:00"), status: .open)
        o.limit = 100; o.plannedStop = 95; o.plannedTarget = 110
        account.orders = [o]
        XCTAssertTrue(PathTasks.isDone(PathTask(kind: .bracket, instruction: ""), since: since, account: account, learning: learning))
        XCTAssertTrue(PathTasks.isDone(PathTask(kind: .sizeByRisk, instruction: ""), since: since, account: account, learning: learning), "risk $50 ≤ 2% of 10k")
        XCTAssertTrue(PathTasks.isDone(PathTask(kind: .limitOrder, instruction: ""), since: since, account: account, learning: learning))
        XCTAssertFalse(PathTasks.isDone(PathTask(kind: .limitOrder, instruction: ""), since: et("2026-03-03 09:00"), account: account, learning: learning), "only counts after the lesson started")
        var acted = LearningState(); acted.actions["scanner"] = et("2026-03-02 11:00")
        XCTAssertTrue(PathTasks.isDone(PathTask(kind: .scanner, instruction: ""), since: since, account: account, learning: acted))
    }

    func testPreTradeCheck() {
        var request = OrderRequest(symbol: "AAPL", side: .buy, shares: 100, type: .market)
        var inputs = PreTradeInputs(request: request, entry: 100, equity: 10_000, bid: 99, ask: 101, averageVolume: 200_000,
                                    nextEarnings: et("2026-03-03 16:00"), sma50: 120, lastClose: 100,
                                    lastLossAt: et("2026-03-02 09:59"), consecutiveLosses: 3, now: et("2026-03-02 10:00"))
        var ids = Set(PreTradeCheck.notes(inputs).map(\.id))
        XCTAssertEqual(ids, ["no-stop", "big-position", "earnings", "wide-spread", "thin", "trend", "revenge", "streak"])
        XCTAssertEqual(PreTradeCheck.notes(inputs).first?.level, .warning)
        request.stopLoss = 90
        inputs.request = request
        ids = Set(PreTradeCheck.notes(inputs).map(\.id))
        XCTAssertTrue(ids.contains("big-risk"), "$1,000 risk is 10% of equity")
        XCTAssertFalse(ids.contains("no-stop"))
        // Closing an existing position gets no coaching.
        inputs.request = OrderRequest(symbol: "AAPL", side: .sell, shares: 100, type: .market)
        inputs.currentShares = 100
        XCTAssertTrue(PreTradeCheck.notes(inputs).isEmpty)
    }

    func testTiltGuardAndReview() {
        let trips = [trip(-10, exit: "2026-03-02 10:00"), trip(-10, exit: "2026-03-02 10:10"), trip(20, exit: "2026-03-02 09:50"),
                     trip(-10, exit: "2026-03-02 10:20")]
        XCTAssertEqual(TiltGuard.consecutiveLosses(trips), 3)
        XCTAssertEqual(TiltGuard.lastLoss(trips), et("2026-03-02 10:20"))

        var entry = PracticeOrder(symbol: "AAPL", side: .buy, shares: 10, type: .market, submittedAt: et("2026-03-02 09:40"),
                                  status: .filled, thesis: "Breakout over yesterday's high")
        entry.fillPrice = 100
        let good = TradeReview.review(trip(-50, exit: "2026-03-02 10:00"), entry: entry, note: TradeNote(followedPlan: true), equity: 10_000)
        XCTAssertEqual(good.grade, "A")
        XCTAssertTrue(good.headline.hasPrefix("Good process, bad result"))
        let bad = TradeReview.review(trip(-200, stop: nil, exit: "2026-03-02 10:00"), entry: nil, note: TradeNote(followedPlan: false), equity: 10_000)
        XCTAssertEqual(bad.grade, "F")
        let blewStop = TradeReview.review(trip(-120, exit: "2026-03-02 10:00"), entry: entry, note: nil, equity: 10_000)
        XCTAssertTrue(blewStop.items.contains { !$0.passed && $0.text.contains("more than you planned") })
    }

    func testWeeklyReportFixAndStreak() {
        let now = et("2026-03-06 17:00")
        var trips: [RoundTrip] = []
        for i in 0..<12 { trips.append(trip(i % 2 == 0 ? 30 : -10, stop: i < 4 ? nil : 95, exit: "2026-03-05 1\(i % 6):00")) }
        let report = WeeklyReport.build(trips: trips, account: AccountData(initialBalance: 10_000), notes: [:], equity: 10_000, now: now)
        XCTAssertEqual(report.trades, 12)
        XCTAssertTrue(report.fix.hasPrefix("Put a stop loss on every trade"), report.fix)
        XCTAssertEqual(report.processStreak, 0)
        let clean = (0..<3).map { trip(10, exit: "2026-03-0\($0 + 3) 10:00") }
        let streak = WeeklyReport.build(trips: clean, account: AccountData(initialBalance: 10_000), notes: [:], equity: 10_000, now: now)
        XCTAssertEqual(streak.processStreak, 3)
        XCTAssertNotNil(streak.praise)
    }

    func testReadiness() {
        var learning = LearningState()
        learning.profile = LearnerProfile(birthYear: 2010)
        let units = [PathUnit(id: "u1", title: "", summary: "", lessons: [PathLesson(id: "a", title: "", minutes: 1, pages: [], quiz: [])])]
        var items = Readiness.items(trips: [], learning: learning, units: units, now: et("2026-03-02 10:00"))
        XCTAssertFalse(Readiness.canOverride(items), "minors can't override")
        learning.profile?.birthYear = 1990
        learning.progress["a"] = LessonProgress(completedAt: et("2026-03-01 10:00"))
        let trips = (0..<60).map { i in trip(5, exit: "2026-01-\(String(format: "%02d", 15 + i % 15)) 10:00") }
        items = Readiness.items(trips: trips, learning: learning, units: units, now: et("2026-03-02 10:00"))
        XCTAssertTrue(Readiness.canOverride(items))
        XCTAssertTrue(items.first { $0.id == "trades" }!.met)
        XCTAssertTrue(items.first { $0.id == "stops" }!.met)
        XCTAssertTrue(items.first { $0.id == "lessons" }!.met)
        XCTAssertTrue(items.first { $0.id == "profit" }!.met)
        XCTAssertFalse(items.first { $0.id == "weeks" }!.met, "under 8 weeks since the first trade")
        XCTAssertFalse(Readiness.isReady(items))
    }

    func testSizingSimulation() {
        var inputs = SizingSimulation.Inputs(winRate: 0.4, winR: 2, lossR: 1, riskFraction: 0.01, trades: 200, paths: 400)
        let small = SizingSimulation.run(inputs, seed: 7)
        XCTAssertEqual(small.expectancyR, 0.2, accuracy: 1e-9)
        XCTAssertEqual(small, SizingSimulation.run(inputs, seed: 7), "seeded runs repeat")
        XCTAssertGreaterThan(small.medianEnding, inputs.startingBalance)
        inputs.riskFraction = 0.10
        let big = SizingSimulation.run(inputs, seed: 7)
        XCTAssertGreaterThan(big.ruinProbability, small.ruinProbability)
        XCTAssertGreaterThan(big.medianMaxDrawdown, small.medianMaxDrawdown)
        XCTAssertEqual(small.samplePaths.count, 5)
        XCTAssertEqual(small.samplePaths[0].count, 201)
        XCTAssertGreaterThanOrEqual(SizingSimulation.typicalLosingStreak(winRate: 0.4, trades: 200), 5)
    }

    func testInvestingMath() {
        let prices = [(et("2026-01-30 16:00"), 100.0), (et("2026-02-27 16:00"), 50.0), (et("2026-03-31 16:00"), 100.0)]
        let dca = InvestingMath.dollarCostAverage(prices: prices.map { (date: $0.0, close: $0.1) }, monthly: 100)
        XCTAssertEqual(dca.contributed, 300)
        XCTAssertEqual(dca.value, 400, accuracy: 1e-9, "1 + 2 + 1 shares at $100")
        let monthly = InvestingMath.monthlyCloses(bars([1, 2, 3]) + [Bar(time: et("2026-04-01 10:00"), open: 4, high: 4, low: 4, close: 4, volume: 0)])
        XCTAssertEqual(monthly.map(\.close), [3, 4])
        XCTAssertEqual(InvestingMath.compound(initial: 1000, monthly: 0, annualReturn: 0, years: 5).value, 1000)
        XCTAssertEqual(InvestingMath.tradingCosts(tradesPerDay: 1, positionSize: 10_000, spreadBps: 2, slippageBps: 1, commissionPerTrade: 0, days: 1), 4, accuracy: 1e-9)
    }

    func testDrills() {
        let up = DrillFactory.build(.trend, symbol: "X", slice: bars((0..<60).map { 100 + Double($0) * 0.5 }), context: bars((0..<80).map { 100 + Double($0) * 0.5 }))
        XCTAssertEqual(up?.answer, 0)
        XCTAssertTrue(DrillGrader.grade(up!, choice: 0).correct)
        let flat = DrillFactory.build(.trend, symbol: "X", slice: bars((0..<60).map { 100 + ($0 % 2 == 0 ? 0.3 : -0.3) }), context: bars((0..<80).map { 100 + ($0 % 2 == 0 ? 0.3 : -0.3) }))
        XCTAssertEqual(flat?.answer, 1)
        let stopDrill = DrillFactory.build(.stop, symbol: "X", slice: bars((0..<60).map { 100 + Double($0) * 0.1 }), context: bars((0..<80).map { 100 + Double($0) * 0.1 }))!
        let zone = stopDrill.stopZone!
        XCTAssertTrue(DrillGrader.grade(stopDrill, stopPrice: (zone.lowerBound + zone.upperBound) / 2).correct)
        XCTAssertFalse(DrillGrader.grade(stopDrill, stopPrice: stopDrill.bars.last!.close + 1).correct)
        XCTAssertFalse(DrillGrader.grade(stopDrill, stopPrice: zone.lowerBound - 5).correct)
        var volume = bars((0..<60).map { 100 + Double($0) * 0.1 })
        volume[59].volume = 5_000_000
        XCTAssertEqual(DrillFactory.build(.volume, symbol: "X", slice: volume, context: volume)?.answer, 0)
        var box = DrillBox()
        box.record(correct: true, now: et("2026-03-02 10:00"))
        XCTAssertEqual(box.box, 1)
        XCTAssertEqual(box.nextDue, et("2026-03-03 10:00"))
        box.record(correct: false, now: et("2026-03-02 10:00"))
        XCTAssertEqual(box.box, 0)
        XCTAssertEqual(box.accuracy, 0.5)
    }
}

final class BrokerTests: XCTestCase {
    func testAlpacaOrderBodyAndValidation() {
        var r = OrderRequest(symbol: "aapl", side: .buy, shares: 10, type: .limit)
        r.limit = d("187.123"); r.tif = .gtc; r.takeProfit = 200; r.stopLoss = d("180.5")
        XCTAssertNil(AlpacaTrading.validate(r))
        let body = AlpacaTrading.orderBody(r, clientOrderID: "x")
        XCTAssertEqual(body["symbol"] as? String, "AAPL")
        XCTAssertEqual(body["qty"] as? String, "10")
        XCTAssertEqual(body["type"] as? String, "limit")
        XCTAssertEqual(body["time_in_force"] as? String, "gtc")
        XCTAssertEqual(body["limit_price"] as? String, "187.12")
        XCTAssertEqual(body["order_class"] as? String, "bracket")
        XCTAssertEqual((body["stop_loss"] as? [String: String])?["stop_price"], "180.5")
        XCTAssertEqual((body["take_profit"] as? [String: String])?["limit_price"], "200")
        var frac = OrderRequest(symbol: "AAPL", side: .buy, shares: d("0.5"), type: .limit); frac.limit = 100
        XCTAssertNotNil(AlpacaTrading.validate(frac))
        XCTAssertNil(AlpacaTrading.validate(OrderRequest(symbol: "AAPL", side: .buy, shares: d("0.5"), type: .market)))
        var ext = OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market); ext.extendedHours = true
        XCTAssertNotNil(AlpacaTrading.validate(ext))
        var wrong = OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market); wrong.stopLoss = 110; wrong.takeProfit = 100
        XCTAssertNotNil(AlpacaTrading.validate(wrong))
        var trail = OrderRequest(symbol: "AAPL", side: .sell, shares: 1, type: .trailingStop); trail.trailPercent = d("0.015")
        XCTAssertEqual(AlpacaTrading.orderBody(trail)["trail_percent"] as? String, "1.5")
        var oto = OrderRequest(symbol: "AAPL", side: .buy, shares: 1, type: .market); oto.stopLoss = 90
        XCTAssertEqual(AlpacaTrading.orderBody(oto)["order_class"] as? String, "oto")
    }

    func testAlpacaParsing() {
        let account = AlpacaTrading.account(Data(#"{"account_number":"PA1","status":"ACTIVE","cash":"1000.5","equity":"1500","last_equity":"1400","buying_power":"3000","daytrade_count":2,"pattern_day_trader":false,"trading_blocked":false,"account_blocked":false,"shorting_enabled":true}"#.utf8))
        XCTAssertEqual(account?.dayChange, 100)
        XCTAssertEqual(account?.dayTradeCount, 2)
        let positions = AlpacaTrading.positions(Data(#"[{"symbol":"TSLA","qty":"5","side":"short","avg_entry_price":"200","market_value":"-1000","unrealized_pl":"-25.5","current_price":"205","change_today":"0.01"}]"#.utf8))
        XCTAssertEqual(positions.first?.quantity, -5)
        XCTAssertEqual(positions.first?.unrealized, d("-25.5"))
        let orders = AlpacaTrading.orders(Data(#"[{"id":"o1","symbol":"AAPL","side":"buy","type":"limit","qty":"10","filled_qty":"0","limit_price":"150","status":"new","time_in_force":"day","order_class":"bracket","submitted_at":"2026-03-02T15:00:01.123456789Z","legs":[{"id":"o2","symbol":"AAPL","side":"sell","type":"stop","qty":"10","filled_qty":"0","stop_price":"145","status":"held","time_in_force":"day"}]}]"#.utf8))
        XCTAssertEqual(orders.first?.legs.first?.statusText, "Waiting (activates after the first order fills)")
        XCTAssertTrue(orders.first?.isOpen ?? false)
        XCTAssertEqual(orders.first!.submittedAt!.timeIntervalSince1970, et("2026-03-02 10:00:01").addingTimeInterval(0.123).timeIntervalSince1970, accuracy: 0.002)
        XCTAssertEqual(AlpacaTrading.errorMessage(status: 403, data: Data(#"{"message":"insufficient buying power"}"#.utf8)), "Not enough buying power for this order.")
        XCTAssertTrue(AlpacaTrading.errorMessage(status: 401, data: Data()).contains("Reconnect"))
    }
}
