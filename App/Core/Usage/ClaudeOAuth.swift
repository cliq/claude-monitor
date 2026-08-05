import Foundation

/// Stored OAuth credentials as Claude Code keeps them in the Keychain.
struct ClaudeOAuth {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double // unix ms
    var subscriptionType: String?
}
