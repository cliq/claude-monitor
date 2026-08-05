import Foundation
import CoreGraphics

private enum UsageAPI {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURLs = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
    ]
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code's public OAuth client id
    static let userAgent = "claude-code/2.0.0" // required; generic agents get 429
}

/// Polls Anthropic's OAuth usage endpoint for each discovered Claude Code
/// account, refreshing tokens as needed, and watches the Mac's display power
/// state (mirrored to the ESP32 panel backlight via `UsageBridgeServer`).
///
/// The usage endpoint is undocumented/community-discovered; it requires a
/// `claude-code/…` User-Agent and a ≥180s poll interval to avoid 429s.
@MainActor
final class UsagePoller: ObservableObject {
    @Published var accounts: [AccountUsage] = []
    @Published var updatedAt: Date?
    @Published var displayOn: Bool = true

    static let pollInterval: TimeInterval = 180 // below this the API 429s

    private let accountsProvider: () -> [UsageAccountConfig]
    private let publish: (UsageSnapshot) -> Void
    private var pollTimer: Timer?
    private var displayTimer: Timer?

    init(accountsProvider: @escaping () -> [UsageAccountConfig] = { UsageAccountConfig.discover() },
         publish: @escaping (UsageSnapshot) -> Void = { _ in }) {
        self.accountsProvider = accountsProvider
        self.publish = publish
    }

    func start() {
        guard pollTimer == nil else { return }
        Task { await self.pollAll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollAll() }
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            Task { @MainActor in self?.displayOn = !asleep }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func snapshot() -> UsageSnapshot {
        let fmt = ISO8601DateFormatter()
        return UsageSnapshot(updatedAt: updatedAt.map { fmt.string(from: $0) }, accounts: accounts)
    }

    func pollAll() async {
        // Re-discover on every cycle so logins added/removed while the app is
        // running show up without a restart.
        let configs = accountsProvider()
        var results: [AccountUsage] = []
        for config in configs {
            do {
                let oauth = try await validOAuth(for: config)
                let raw = try await fetchUsage(token: oauth.accessToken)
                results.append(Self.summarize(raw: raw, name: config.name,
                                              plan: oauth.subscriptionType ?? ""))
            } catch {
                var failed = AccountUsage(name: config.name, status: "error")
                failed.error = String(error.localizedDescription.prefix(200))
                results.append(failed)
            }
        }
        accounts = results
        updatedAt = Date()
        // @Published emits on willSet, so an external Combine sink observing
        // `accounts`/`updatedAt` individually could pair new accounts with the
        // old timestamp; publish only after both fields are consistent.
        publish(snapshot())
    }

    // MARK: - OAuth

    nonisolated private func validOAuth(for config: UsageAccountConfig) async throws -> ClaudeOAuth {
        let service = ClaudeCodeKeychain.serviceName(configDir: config.configDir)
        var payload = try ClaudeCodeKeychain.read(service: service)
        guard var oauthDict = payload["claudeAiOauth"] as? [String: Any],
              let accessToken = oauthDict["accessToken"] as? String,
              let refreshToken = oauthDict["refreshToken"] as? String,
              let expiresAt = (oauthDict["expiresAt"] as? NSNumber)?.doubleValue else {
            throw NSError(domain: "UsagePoller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no claudeAiOauth in keychain item"])
        }
        var oauth = ClaudeOAuth(accessToken: accessToken, refreshToken: refreshToken,
                                expiresAt: expiresAt,
                                subscriptionType: oauthDict["subscriptionType"] as? String)
        let marginMs: Double = 5 * 60 * 1000
        if oauth.expiresAt - marginMs < Date().timeIntervalSince1970 * 1000 {
            oauth = try await refresh(oauth)
            // Mutate only the token fields; preserve everything else in the payload.
            oauthDict["accessToken"] = oauth.accessToken
            oauthDict["refreshToken"] = oauth.refreshToken
            oauthDict["expiresAt"] = oauth.expiresAt
            payload["claudeAiOauth"] = oauthDict
            try ClaudeCodeKeychain.write(service: service, payload: payload) // keep Claude Code logged in
        }
        return oauth
    }

    nonisolated private func refresh(_ oauth: ClaudeOAuth) async throws -> ClaudeOAuth {
        struct TokenResponse: Codable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        var lastError: Error = NSError(domain: "UsagePoller", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "token refresh failed"])
        for url in UsageAPI.tokenURLs {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": oauth.refreshToken,
                "client_id": UsageAPI.clientID,
            ])
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "UsagePoller", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "refresh HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
                }
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                var updated = oauth
                updated.accessToken = token.accessToken
                if let rt = token.refreshToken { updated.refreshToken = rt }
                updated.expiresAt = Date().timeIntervalSince1970 * 1000 + token.expiresIn * 1000
                return updated
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Usage

    nonisolated private func fetchUsage(token: String) async throws -> [String: Any] {
        var req = URLRequest(url: UsageAPI.usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "UsagePoller", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "usage HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        return json
    }

    // Thin forwarders so existing call sites (and `Tests/UsagePollerTests.swift`)
    // keep compiling — the actual implementation lives in `UsageFormat` so it
    // can be shared without pulling in this poller's networking/keychain deps.
    nonisolated static func summarize(raw: [String: Any], name: String, plan: String) -> AccountUsage {
        UsageFormat.summarize(raw: raw, name: name, plan: plan)
    }

    /// Absolute local reset time: "23:50" if today, else "Fri 12:00".
    nonisolated static func formatReset(_ iso: String?) -> String {
        UsageFormat.formatReset(iso)
    }
}
