# TradePilot / Trading Lab

A SwiftUI trading education and practice app for iPhone, iPad, and Mac. It includes market charts, watchlists, a simulated trading account, learning activities, a trading journal, and optional account and brokerage integrations.

## Open in Xcode

1. Clone this repository and open `TradePilot.xcodeproj`.
2. Use Xcode 27 or later. The project uses Xcode's JSON project format (`project.xcproj`).
3. Select the **TradePilot** scheme and **My Mac** or an installed iPhone simulator.
4. For a physical device, select your own development team and bundle identifier under **Signing & Capabilities**.
5. Press **Command-R** to build and run.

The app entry point is `TradePilot/MyApp.swift`; its main view is `TradePilot/TradingLab/Views/ContentView.swift`.

## Configuration

Review `TradePilot/TradingLab/App/Config.swift` before using connected features. It contains the backend URL and a placeholder Google OAuth client ID. Authentication, sync, and server-backed AI features require the corresponding backend configuration; backend source is not included in this repository. Apple sign-in requires the appropriate capability and provisioning. Brokerage credentials are entered in the app and stored in the device Keychain; keep credentials out of source control.

Make sure `TradePilot/TradingLab/Resources/Lessons.json` is bundled with the app. The project's source folder excludes `TradingLab/Tests/TradingLabCoreTests.swift` from the app target. To run those tests, create a unit-test target, add that file there, and change its fallback `@testable import TradingLab` to your app's module name (`TradePilot` for this project).

## Source layout

- `Core/`: trading simulation, accounting, indicators, chart calculations, persistence, learning, and analytics.
- `Services/`: networking, market data, account access, AI, brokerage integration, and Keychain storage.
- `Store/`: app state and coordination.
- `Views/` and `DesignSystem/`: SwiftUI screens and shared styling.
- `Resources/`: lesson content.
- `Tests/`: core regression tests.

See [the detailed app notes](TradePilot/TradingLab/README.md) for feature descriptions. These notes may describe setup for other package versions; the Xcode instructions above apply to this repository.

## Validation status

This upload includes the current local source and recent Combine-import and target-membership fixes. A successful full Xcode build and end-to-end verification of connected services have not been confirmed.
