import Foundation
import CryptoKit

/// Reads/writes the Keychain items Claude Code stores its OAuth credentials in.
/// Service name: "Claude Code-credentials-<first 8 hex of sha256(config_dir)>".
///
/// Access goes through the `security` CLI rather than SecItemCopyMatching:
/// Claude Code creates these items via the same binary, so `security` is on
/// their ACL and reads/writes never trigger a permission dialog.
///
/// Distinct from `KeychainStore`, which manages this app's own items via
/// Security.framework — these items belong to Claude Code, not us.
enum ClaudeCodeKeychain {
    static func serviceName(configDir: String) -> String {
        let digest = SHA256.hash(data: Data(configDir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(hex)"
    }

    /// The full JSON payload of the item as a plain dictionary. The payload
    /// holds more than claudeAiOauth (e.g. mcpOAuth server credentials), so it
    /// must be round-tripped untouched — never modeled with strict Codable.
    static func read(service: String) throws -> [String: Any] {
        let out = try run(["find-generic-password", "-s", service, "-w"])
        guard let dict = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            throw NSError(domain: "ClaudeCodeKeychain", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "credential payload is not a JSON object"])
        }
        return dict
    }

    static func write(service: String, payload: [String: Any]) throws {
        let account = try accountName(service: service)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8)!
        _ = try run(["add-generic-password", "-U", "-s", service, "-a", account, "-w", json])
    }

    /// The -a attribute of the existing item (needed to update it in place).
    private static func accountName(service: String) throws -> String {
        let out = try run(["find-generic-password", "-s", service])
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"acct\"<blob>=") {
                return trimmed.replacingOccurrences(of: "\"acct\"<blob>=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return ""
    }

    private static func run(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ClaudeCodeKeychain", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "security \(args.first ?? "") failed: \(err.prefix(120))"])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
