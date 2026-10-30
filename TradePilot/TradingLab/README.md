# Trading Lab 3.1 (iOS 17+ / macOS 14+)

## Install

1. Delete the old single-file `ContentView.swift` from your Xcode project.
2. Drag this whole `TradingLab` folder into the project, checking the iOS and macOS app targets. Leave `Tests/` out of the app targets.
3. Make sure `Resources/Lessons.json` is in **Copy Bundle Resources** for both targets. Xcode 16+ folder references do this automatically.
4. Signing & Capabilities on each target: add **Sign in with Apple**. Keep your App Group (`group.com.tradinglab.shared`) for the widget.
5. Point `App/Config.swift` → `AppConfig.serverURL` at your deployed server (see `server/README.md`).
6. Tests: add `Tests/TradingLabCoreTests.swift` to your unit-test target. It does `@testable import TradingLab`; rename that if your app module has a different name.

Your existing `@main` App struct keeps showing `ContentView()`.

## Layout

| Folder | What's in it |
|---|---|
| `Core/` | Pure Swift, no UI, covered by tests: orders and the `OrderEngine` brokerage simulator, the Decimal `Ledger` with margin, NYSE `MarketHours` with extended sessions, bars and `Indicators`, chart math, `TradeAnalytics`, `ReplaySession`, the scanner and alert rules, sync `WorkspaceMerge`, persistence, feed parsers. |
| `Services/` | `MarketData` (prices, charts, IEX stream), `NewsStore`, `AccountService` (Sign in with Apple), `AIImpactModel` (Gemini), `Keychain`, networking |
| `Store/` | `LabStore`: the workspace, orders, schedules, alerts, persistence and sync engine |
| `DesignSystem/` | `Theme` (injected through the environment), shared components |
| `Views/` | `Today/` (Home), `Chart/` (the chart engine and Chart tab), `Trade/` (order ticket, blotter), `Scan/`, `Journal/`, `Replay/`, `News/`, `Learn/`, `Profile/`, `Stock/`, `Tools/`, `Shared/` |
| `Resources/Lessons.json` | Lessons, short lessons, glossary and the replay scenario |

## What's new in 3.1: learning, coaching and real trading

**First launch**: a short, fading question flow (name, age, experience, goals, weekly time, how you'd react to a drop, practice balance), then account creation with Sign in with Apple. Beginners start in a cash account with a daily loss limit; experienced traders get everything unlocked. Under 13s can't continue; under 18s stay in practice mode.

**Learning path** (Learn tab): 5 units, 31 short lessons in plain English, each with a quiz and most with a hands-on task the app checks in your practice account (place a bracket, size a trade at 1% risk, draw a support line, finish a replay…). Short selling, margin, advanced orders and extended hours unlock when you finish the lesson that explains them.

**Coaching while you trade**
- Pre-trade coach in the order ticket: no stop loss, risking more than 2%, earnings tomorrow, wide spread, thin volume, trading against the 50-day trend, revenge trading, losing streaks, overtrading. Each links to the lesson.
- Tilt guard: after three losses in a row the app offers a 15-minute break (you can still close positions).
- Every closed trade gets a process grade (A–F) based on how it was traded, not whether it won: stop loss, loss within plan, size, plan followed, reason written.
- Weekly report card with one specific fix, best/worst setup and hour, and a good-habit streak.

**Explore and practice**
- "?" explanations next to jargon everywhere, a 96-term plain-English glossary with diagrams.
- Chart drills on real past charts (spot the trend, place the stop, read the volume) with spaced repetition.
- Position-size lab: Monte Carlo of 1,000 futures using your own win rate, showing risk of ruin and drawdowns.
- Investing vs trading: dollar-cost averaging with real SPY history, compounding, and what frequent trading costs.
- Daily market brief: indexes, sector heat map in plain words, headlines, and upcoming CPI, jobs-report and Fed dates (from BLS and the Federal Reserve; 2027 Fed dates are tentative).
- Famous market days: day-by-day replays of the 2020 COVID crash, the 2021 GameStop squeeze and the 2023 bank scare, with decisions to make and a comparison against holding.
- Company explainer on each stock: revenue and profit by year from SEC filings, P/E and beta in plain words, and an optional AI summary of how the company makes money.
- AI tutor that sees your practice stats and the chart you're on; it teaches and never says what to buy or sell.

**Real-money trading (Alpaca)**
- Settings → Real-money trading. A readiness checklist (18+, 50 practice trades, 8 weeks, profitable recently, stops on 90% of trades, safety lessons) gates live accounts; adults can override by typing an acknowledgment. Alpaca paper accounts work any time.
- Connect with **API keys** (stored in the Keychain on that device only) or **Sign in with Alpaca** (OAuth; needs `ALPACA_CLIENT_ID`/`ALPACA_CLIENT_SECRET` on your server and a registered redirect URI `tradinglab://alpaca-oauth`).
- The Chart tab gets a PRACTICE / ALPACA switch: real orders (market, limit, stop, stop-limit, trailing stop, brackets) with mandatory confirmation, draggable order lines that replace the order at Alpaca, live positions, open orders and fills. The coach still runs on real orders.
- Robinhood and Fidelity aren't included: neither offers an API for third-party apps to place stock orders (Robinhood's 2026 "Agentic Trading" is limited to AI agents and a separate account; Fidelity connections through aggregators are read-only).
- App Store: Apple's guidelines say trading apps should come from the financial institution. Real trading is fine for personal builds but may be rejected in review.

## What's in 3.0

Five tabs: **Home, Chart, Scan, News, Learn**. Profile and settings are the person icon on Home.

**Chart** (Canvas-drawn, no chart library)
- Candles, hollow candles, Heikin-Ashi, OHLC bars, line, area. 1m, 5m, 15m, 1h, 1D, 1W.
- Indicators: VWAP, SMA, EMA, Bollinger Bands on the chart; RSI, MACD, ATR, Stochastic in panes. Any number, any length, your colors.
- Drawings saved per symbol and synced: horizontal line, trend line, ray, rectangle, Fibonacci retracement, plus a measure tool. Magnet snaps to OHLC.
- Pan, pinch-zoom, long-press crosshair (hover on Mac), pre/post-market shading, day separators, previous close, earnings markers.
- Your working orders are lines you drag to a new price. Position line with live P&L, fill arrows on the bars.
- Crosshair "+": buy/sell limit or stop at that price, set an alert, or draw a line.
- One-tap Buy/Sell at the bid/ask with a quantity stepper, Flatten, Level 1 bid/ask, time & sales. iPad and Mac get a trading sidebar.
- Keyboard (iPad/Mac): ⌘1–⌘6 timeframes, ⌘K symbol, ⌘T ticket, ⇧⌘B buy, ⇧⌘S sell, ⇧⌘F flatten, Esc stops drawing.

**Orders** (realistic simulator; nothing reaches a broker)
- Market, limit, stop, stop-limit, trailing stop ($ or %). Day or GTC. Extended-hours limits 4:00–20:00 ET.
- Brackets: stop loss and take profit, OCO, active once the entry fills. Presets in R (1R/2R/3R) and ATR.
- Size by shares, dollars, or risk (% of equity to the stop). Live preview: risk if stopped, reward:risk, buying power, maintenance.
- Fills: buys pay the ask, sells hit the bid (IEX quote, or a modeled spread), market/stop slippage, optional commissions. Or "last price" fills.
- Long and short. Cash account (T+1 settlement, no shorting) or margin (Reg T 2× buying power, house maintenance checked intraday). Choose FINRA's 2026 intraday-margin rule or the legacy PDT rule.
- Guardrails: daily loss limit lockout, max position size, require a stop, confirmations.

**Scanner**: top gainers/losers, most active, gap up/down, unusual volume, small-cap movers, with price/volume/RVOL/market-cap filters. Tap a row to chart it.

**Journal**: round trips built from fills (partials and flips handled), win rate, profit factor, expectancy, average R, drawdown, hold times; cumulative P&L curve; P&L calendar; breakdowns by setup, symbol, side, hour, weekday and hold time; every trade on its chart with fills, plan and review. CSV export.

**Bar replay**: pick a recent session, reveal it bar by bar (or play at 0.5–10×), and trade it with the same engine in a $25k sandbox. Results are saved.

**Alerts**: price, % change, VWAP cross, RSI(14, 5m), relative volume. One-shot or repeating, with a note.

**Data**: live IEX trades and quotes through your own Alpaca keys (Settings → Market prices), Yahoo delayed bars and screeners otherwise, Finnhub fundamentals and earnings through your server.

## Known limits

- No Apple SDK was available while building this. Core and the server are compiled and unit-tested; Services and the Store compile in Swift 6 mode against stand-ins for Apple frameworks; the SwiftUI views type-check against a SwiftUI stand-in. Expect a small number of fixes the first time you build in Xcode, mostly in iOS-only code paths.
- IEX is one exchange: its bid/ask and prints are a subset of the full market (SIP). Volume on the chart comes from Yahoo bars.
- Yahoo's screener and intraday bars are unofficial endpoints and can change. 1-minute history covers about 5 sessions; 5-minute about a month.

## What changed for existing users

- **Data moves to a file.** On first launch, everything in UserDefaults (account, portfolios, history, notes, added tickers) is read once, written to `Application Support/TradingLab/workspace.json`, and the old keys are removed.
- **Money is exact.** v1's float noise is trimmed (`0.30000000000000004` → `0.3`). Cash is now derived from the starting balance and filled orders. For v1 accounts the true starting balance is recovered from saved cash, which undoes the old $10k/$100k migration bug.
- **Sync now uses Sign in with Apple.** The old recovery key is deleted from the Keychain and the old endpoint returns 410. Users sign in once, from Settings, and their local data is merged into the account.
- **Nothing is public by default.** The records page shows only a nickname and return %, and only for people who turn it on.
- **Articles open at the publisher.** The app shows the headline, the publisher summary when the feed has one, and Safari (iOS) or the default browser (macOS). Article text is no longer copied into the app.
- **Market hours are real.** Market orders placed while the market is closed are queued and fill at the first in-session price after the next open, or are canceled if that price is more than the user can afford.
- **3.0 upgrade.** Old orders, alerts and settings decode into the new formats (old orders become GTC; old price alerts become price conditions). Accounts default to margin with the 2026 rule, realistic fills and order confirmations on; change this in Settings → Trading.
