import XCTest
@testable import ClaudeMonitor

final class UsageModelsTests: XCTestCase {
    // MARK: - Account naming

    func test_accountName_stripsClaudewhoPrefix() {
        XCTAssertEqual(UsageAccountConfig.accountName(forDirectoryNamed: ".claudewho-personal"), "personal")
        XCTAssertEqual(UsageAccountConfig.accountName(forDirectoryNamed: ".claudewho-cliq"), "cliq")
    }

    func test_accountName_plainClaudeDir() {
        XCTAssertEqual(UsageAccountConfig.accountName(forDirectoryNamed: ".claude"), "claude")
    }

    func test_accountName_emptySuffixFallsBackToClaude() {
        XCTAssertEqual(UsageAccountConfig.accountName(forDirectoryNamed: ".claudewho-"), "claude")
    }

    // MARK: - Discovery

    func test_discover_mapsConfigDirsToNamedAccounts() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageModelsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        for dir in [".claudewho-b", ".claudewho-a", ".claude", ".other"] {
            let url = home.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if dir != ".other" {
                try Data("{}".utf8).write(to: url.appendingPathComponent("settings.json"))
            }
        }
        // No settings.json → excluded, same rule the hook installer uses.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claudewho-no-settings"),
            withIntermediateDirectories: true)

        let accounts = UsageAccountConfig.discover(home: home)
        XCTAssertEqual(accounts.map(\.name), ["claude", "a", "b"])
        XCTAssertEqual(accounts.map(\.configDir),
                       [".claude", ".claudewho-a", ".claudewho-b"].map { home.appendingPathComponent($0).path })
    }

    // MARK: - JSON schema (what the ESP32 firmware parses)

    func test_snapshotEncodesFirmwareSchema() throws {
        var account = AccountUsage(name: "personal", status: "ok")
        account.plan = "MAX"
        account.sessionPct = 43
        account.sessionResets = "23:50"
        account.weeklyPct = 12
        account.weeklyResets = "Fri 12:00"
        account.modelPct = 7
        account.modelResets = "Sat 09:00"
        account.modelLabel = "FABLE"

        let snapshot = UsageSnapshot(updatedAt: "2026-07-19T12:00:00Z", accounts: [account])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]

        XCTAssertEqual(json["updated_at"] as? String, "2026-07-19T12:00:00Z")
        let first = (json["accounts"] as! [[String: Any]])[0]
        XCTAssertEqual(first["name"] as? String, "personal")
        XCTAssertEqual(first["session_pct"] as? Int, 43)
        XCTAssertEqual(first["session_resets"] as? String, "23:50")
        XCTAssertEqual(first["weekly_pct"] as? Int, 12)
        XCTAssertEqual(first["weekly_resets"] as? String, "Fri 12:00")
        XCTAssertEqual(first["model_pct"] as? Int, 7)
        XCTAssertEqual(first["model_resets"] as? String, "Sat 09:00")
        XCTAssertEqual(first["model_label"] as? String, "FABLE")
    }
}
