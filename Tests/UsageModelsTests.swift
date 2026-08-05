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

    // MARK: - Ordering / rename / disable

    private let a = UsageAccountConfig(name: "a", configDir: "/h/.claudewho-a")
    private let b = UsageAccountConfig(name: "b", configDir: "/h/.claudewho-b")
    private let c = UsageAccountConfig(name: "c", configDir: "/h/.claudewho-c")

    func test_ordered_appliesSavedOrderAndAppendsNewDirs() {
        let out = UsageAccountConfig.ordered(discovered: [a, b, c],
                                             order: ["/h/.claudewho-c", "/h/.claudewho-a"])
        XCTAssertEqual(out.map(\.name), ["c", "a", "b"])
    }

    func test_ordered_ignoresVanishedDirsInSavedOrder() {
        let out = UsageAccountConfig.ordered(discovered: [a, b],
                                             order: ["/h/.claudewho-gone", "/h/.claudewho-b"])
        XCTAssertEqual(out.map(\.name), ["b", "a"])
    }

    func test_resolve_filtersDisabledAccounts() {
        let out = UsageAccountConfig.resolve(discovered: [a, b, c], order: [],
                                             disabledDirs: ["/h/.claudewho-b"],
                                             customNames: [:])
        XCTAssertEqual(out.map(\.name), ["a", "c"])
    }

    func test_resolve_appliesCustomNames() {
        let out = UsageAccountConfig.resolve(discovered: [a, b], order: [],
                                             disabledDirs: [],
                                             customNames: ["/h/.claudewho-a": "work"])
        XCTAssertEqual(out.map(\.name), ["work", "b"])
    }

    func test_resolve_blankCustomNameFallsBackToDefault() {
        let out = UsageAccountConfig.resolve(discovered: [a], order: [],
                                             disabledDirs: [],
                                             customNames: ["/h/.claudewho-a": "   "])
        XCTAssertEqual(out.map(\.name), ["a"])
    }

    func test_resolve_combinesOrderRenameAndDisable() {
        let out = UsageAccountConfig.resolve(
            discovered: [a, b, c],
            order: ["/h/.claudewho-c", "/h/.claudewho-b", "/h/.claudewho-a"],
            disabledDirs: ["/h/.claudewho-b"],
            customNames: ["/h/.claudewho-c": "main"])
        XCTAssertEqual(out.map(\.name), ["main", "a"])
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

    // MARK: - Legacy payload compatibility (written before *_resets_at/schema_version existed)

    func test_decode_legacyAccountWithoutResetsAtFields_decodesWithNilResetsAt() throws {
        let json = """
        {
          "name": "personal",
          "status": "ok",
          "plan": "MAX",
          "session_pct": 43,
          "session_resets": "23:50",
          "weekly_pct": 12,
          "weekly_resets": "Fri 12:00",
          "model_pct": 7,
          "model_resets": "Sat 09:00",
          "model_label": "FABLE"
        }
        """
        let account = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))

        XCTAssertEqual(account.name, "personal")
        XCTAssertEqual(account.sessionPct, 43)
        XCTAssertNil(account.sessionResetsAt)
        XCTAssertNil(account.weeklyResetsAt)
        XCTAssertNil(account.modelResetsAt)
    }

    func test_decode_legacySnapshotWithoutSchemaVersion_defaultsToOne() throws {
        let json = """
        {
          "updated_at": "2026-07-19T12:00:00Z",
          "accounts": [
            {
              "name": "personal",
              "status": "ok",
              "plan": "MAX",
              "session_pct": 43,
              "session_resets": "23:50",
              "weekly_pct": 12,
              "weekly_resets": "Fri 12:00",
              "model_pct": 7,
              "model_resets": "Sat 09:00",
              "model_label": "FABLE"
            }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.accounts.first?.name, "personal")
        XCTAssertNil(snapshot.accounts.first?.sessionResetsAt)
    }

    // MARK: - Wire schema is frozen (ESP32 firmware parses these keys)

    func test_encode_accountUsage_includesLegacyAndNewResetsAtKeys() throws {
        var account = AccountUsage(name: "personal", status: "ok")
        account.plan = "MAX"
        account.sessionPct = 43
        account.sessionResets = "23:50"
        account.sessionResetsAt = "2026-07-19T23:50:00Z"
        account.weeklyPct = 12
        account.weeklyResets = "Fri 12:00"
        account.weeklyResetsAt = "2026-07-24T12:00:00Z"
        account.modelPct = 7
        account.modelResets = "Sat 09:00"
        account.modelResetsAt = "2026-07-25T09:00:00Z"
        account.modelLabel = "FABLE"

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]

        // Legacy keys.
        for key in ["name", "status", "plan", "session_pct", "session_resets",
                    "weekly_pct", "weekly_resets", "model_pct", "model_resets", "model_label"] {
            XCTAssertNotNil(json[key], "missing legacy key \(key)")
        }
        // New raw-ISO keys.
        XCTAssertEqual(json["session_resets_at"] as? String, "2026-07-19T23:50:00Z")
        XCTAssertEqual(json["weekly_resets_at"] as? String, "2026-07-24T12:00:00Z")
        XCTAssertEqual(json["model_resets_at"] as? String, "2026-07-25T09:00:00Z")
    }

    func test_encode_usageSnapshot_includesSchemaVersion() throws {
        let snapshot = UsageSnapshot(updatedAt: "2026-07-19T12:00:00Z", accounts: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]

        XCTAssertEqual(json["schema_version"] as? Int, 1)
    }
}
