import Foundation

nonisolated enum AppConfig {
    /// Your Trading Lab server (see server/README.md). HTTPS only.
    static let serverURL = URL(string: "https://publicspace-communities.crafty-treacle-8i.chatgpt.site")!
    static var recordsURL: URL { serverURL.appending(path: "trading-lab") }
    static func api(_ path: String) -> URL { serverURL.appending(path: "api/trading-lab/" + path) }

    /// Google OAuth client ID for iOS (Google Cloud Console → Credentials → Create OAuth client ID → iOS).
    /// Replace the placeholder. The server's GOOGLE_CLIENT_IDS must list the same ID.
    static let googleClientID = "YOUR_IOS_CLIENT_ID.apps.googleusercontent.com"
    /// Google's iOS redirect uses the client ID reversed, e.g. com.googleusercontent.apps.123-abc.
    static var googleCallbackScheme: String {
        "com.googleusercontent.apps." + googleClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    static var googleRedirectURI: String { googleCallbackScheme + ":/oauth2redirect/google" }

    /// Tried in order. Stable IDs as of Oct 2026 (ai.google.dev/models).
    static let geminiModels = ["gemini-3.8-flash", "gemini-3.5-flash-lite"]

    /// Pending orders and alerts are processed on every tick; the UI redraws at most this often.
    static let marketPublishInterval: Duration = .milliseconds(250)
    static let portfolioRecordInterval: TimeInterval = 60
    static let fetchConcurrency = 6
}
