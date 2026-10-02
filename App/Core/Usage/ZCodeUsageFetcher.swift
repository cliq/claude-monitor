import CryptoKit
import Foundation

/// Fetches Z.ai Coding Plan quota for the account the ZCode desktop app is
/// signed in to. ZCode keeps the plan's API key in `<home>/v2/credentials.json`,
/// AES-GCM-encrypted with a key derived from the user's home and name
/// (`ZCodeCredentialStore`); the key is decrypted in memory and sent to the
/// same quota endpoint ZCode's usage settings call. Read-only: the monitor
/// never writes ZCode's store and never redeems Coding Plan resets.
struct ZCodeUsageFetcher: UsageFetching {
    var session: URLSession = .shared
    var subscriptionCache = ZCodeUsageFetcher.sharedSubscriptionCache
    var resetCache = ZCodeUsageFetcher.sharedResetCache

    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    /// ZCode's own backend; the read-only half of its reset feature (`/use`
    /// redeems one — the monitor never calls it).
    static let resetStatusURL = URL(string: "https://zcode.z.ai/api/v1/coding-plan/reset/status")!

    /// Plan name and renewal date, refreshed hourly.
    static let sharedSubscriptionCache = UsageSideInfoCache<ZaiPlanInfo?>()
    /// Banked resets, refreshed every 10 minutes.
    static let sharedResetCache = UsageSideInfoCache<ZaiResetStatus>()

    func fetch(account: UsageAccountConfig) async throws -> AccountUsage {
        let file = URL(fileURLWithPath: account.configDir)
            .appendingPathComponent("v2").appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: file),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ZCodeUsageError("ZCode credentials not found — sign in to ZCode")
        }
        let credentials = raw.compactMapValues { $0 as? String }
        let key = ZCodeCredentialStore.key(secret: ZCodeCredentialStore.defaultSecret(
            home: FileManager.default.homeDirectoryForCurrentUser.path, username: NSUserName()))
        let apiKey = try ZCodeCredentialStore.codingPlanAPIKey(credentials: credentials, key: key)

        // ZCode sends the plan key verbatim, without a `Bearer` scheme.
        let (body, status) = try await get(Self.quotaURL, headers: ["Authorization": apiKey], timeout: 15)
        guard status == 200 else {
            throw ZCodeUsageError(status == 401
                ? "Z.ai rejected the Coding Plan key — reconnect it in ZCode"
                : "Z.ai quota HTTP \(status)")
        }
        let envelope = try JSONDecoder().decode(ZaiQuotaEnvelope.self, from: body)

        let plan = await subscriptionCache.value(for: account.configDir, ttl: 3600) {
            try await fetchPlanInfo(apiKey: apiKey)
        } ?? nil
        let resets = await resetCache.value(for: account.configDir, ttl: 600) {
            try await fetchResetStatus(credentials: credentials, key: key)
        }
        return try ZaiUsageMapper.summarize(envelope, name: account.name, plan: plan, resets: resets)
    }

    /// Only the plan's name, status and renewal fields are decoded — the list
    /// also carries order and payment details.
    private func fetchPlanInfo(apiKey: String) async throws -> ZaiPlanInfo? {
        let (body, status) = try await get(Self.subscriptionURL, headers: ["Authorization": apiKey], timeout: 10)
        guard status == 200,
              let list = try JSONDecoder().decode(ZaiEnvelope<[ZaiSubscription]>.self, from: body).payload else {
            throw ZCodeUsageError("Z.ai subscription unavailable")
        }
        return ZaiSubscription.currentPlan(in: list)
    }

    /// Uses ZCode's session tokens (kept fresh by the ZCode app), not the plan
    /// key — when they've lapsed this simply yields nothing.
    private func fetchResetStatus(credentials: [String: String], key: SymmetricKey) async throws -> ZaiResetStatus {
        guard let jwt = credentials[ZCodeCredentialStore.sessionTokenKey],
              let maas = credentials[ZCodeCredentialStore.zaiAccessTokenKey] else {
            throw ZCodeUsageError("no ZCode session")
        }
        var session = try ZCodeCredentialStore.decrypt(jwt, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
        if !session.lowercased().hasPrefix("bearer ") { session = "Bearer \(session)" }
        let (body, status) = try await get(Self.resetStatusURL, headers: [
            "Authorization": session,
            "X-Bigmodel-Authorization": try ZCodeCredentialStore.decrypt(maas, key: key)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Bigmodel-Target-Type": "PERSONAL",
        ], timeout: 10)
        guard status == 200,
              let payload = try JSONDecoder().decode(ZaiEnvelope<ZaiResetStatus>.self, from: body).payload else {
            throw ZCodeUsageError("Z.ai reset status unavailable")
        }
        return payload
    }

    private func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        req.setValue(UsageHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct ZCodeUsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = String(message.prefix(200)) }
    var errorDescription: String? { message }
}

// MARK: - Credential store

/// ZCode's `enc:v1:` values: AES-256-GCM, key = SHA-256 of a secret, stored as
/// `enc:v1:<nonce>.<tag>.<ciphertext>` (base64url, 12-byte nonce, 16-byte tag).
/// The secret is `ZCODE_CREDENTIAL_SECRET` when set (invisible to a GUI app —
/// decryption then fails with an actionable error), else a fallback built
/// from Node's `os.platform()`, `os.homedir()` and the user name.
enum ZCodeCredentialStore {
    static let prefix = "enc:v1:"
    /// `account-provider:coding-plan:<providerId>:account:<uuid>:api-key`.
    static let apiKeyPrefix = "account-provider:coding-plan:"
    /// ZCode's own session token and its Z.ai account token — only used for
    /// the read-only reset status.
    static let sessionTokenKey = "zcodejwttoken"
    static let zaiAccessTokenKey = "oauth:zai:access_token"
    /// The only plan whose quota this endpoint serves without team headers.
    static let individualPlanProvider = "account:zai-individual-coding-plan"

    nonisolated static func defaultSecret(home: String, username: String) -> String {
        "zcode-credential-fallback:darwin:\(home):\(username)"
    }

    nonisolated static func key(secret: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }

    /// Plaintext values (no prefix) pass through, as in ZCode.
    nonisolated static func decrypt(_ value: String, key: SymmetricKey) throws -> String {
        guard value.hasPrefix(prefix) else { return value }
        let parts = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let nonce = base64URL(parts[0]), let tag = base64URL(parts[1]), let cipher = base64URL(parts[2]),
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: key),
              let text = String(data: plain, encoding: .utf8) else {
            throw ZCodeUsageError("could not decrypt ZCode credentials (custom ZCODE_CREDENTIAL_SECRET?)")
        }
        return text
    }

    /// The Z.ai individual Coding Plan key. Other plan kinds get a clear
    /// "not supported" rather than a guessed endpoint.
    nonisolated static func codingPlanAPIKey(credentials: [String: String], key: SymmetricKey) throws -> String {
        let planKeys = credentials.keys.filter { $0.hasPrefix(apiKeyPrefix) && $0.hasSuffix(":api-key") }.sorted()
        guard let name = planKeys.first(where: { $0.hasPrefix(apiKeyPrefix + individualPlanProvider + ":") }),
              let stored = credentials[name] else {
            throw ZCodeUsageError(planKeys.isEmpty
                ? "no Coding Plan connected in ZCode"
                : "only Z.ai individual Coding Plans are supported")
        }
        let apiKey = try decrypt(stored, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw ZCodeUsageError("ZCode's Coding Plan key is empty") }
        return apiKey
    }

    private static func base64URL(_ text: Substring) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

// MARK: - Response mapping

/// `GET /api/monitor/usage/quota/limit` — `{code, msg, success, data: {limits, level}}`.
struct ZaiQuotaEnvelope: Decodable, Equatable {
    struct Limit: Decodable, Equatable {
        var type: String
        /// Window unit code as ZCode reads it: 3 = hours, 5 = months, 6 = weeks.
        var unit: Int?
        var number: Int?
        /// The window's allowance.
        var usage: Double?
        var currentValue: Double?
        var remaining: Double?
        var percentage: Double?
        /// Unix milliseconds.
        var nextResetTime: Double?
    }

    struct Payload: Decodable, Equatable {
        var limits: [Limit]?
        var level: String?
    }

    var code: Int?
    var msg: String?
    var success: Bool?
    var data: Payload?
}

/// Z.ai's `{code, msg, success, data}` wrapper.
struct ZaiEnvelope<T: Decodable>: Decodable {
    var code: Int?
    var msg: String?
    var success: Bool?
    var data: T?

    var payload: T? {
        guard success != false, code == nil || code == 0 || code == 200 else { return nil }
        return data
    }
}

/// One `/api/biz/subscription/list` entry (only the fields ZCode itself reads).
struct ZaiSubscription: Decodable, Equatable {
    var productId: String?
    var productName: String?
    var status: String?
    var inCurrentPeriod: Bool?
    var autoRenew: Bool
    var nextRenewTime: String?
    /// "yyyy-MM-dd HH:mm:ss-yyyy-MM-dd HH:mm:ss".
    var valid: String?

    enum CodingKeys: String, CodingKey {
        case productId, productName, status, inCurrentPeriod, autoRenew, nextRenewTime, valid
    }

    init(productId: String? = nil, productName: String?, status: String? = "VALID", inCurrentPeriod: Bool? = true,
         autoRenew: Bool, nextRenewTime: String?, valid: String? = nil) {
        self.productId = productId
        self.productName = productName
        self.status = status
        self.inCurrentPeriod = inCurrentPeriod
        self.autoRenew = autoRenew
        self.nextRenewTime = nextRenewTime
        self.valid = valid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productId = try? c.decodeIfPresent(String.self, forKey: .productId)
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        inCurrentPeriod = try? c.decodeIfPresent(Bool.self, forKey: .inCurrentPeriod)
        // 1/0 or true/false, as ZCode accepts.
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .autoRenew) {
            autoRenew = flag
        } else {
            autoRenew = (try? c.decodeIfPresent(Int.self, forKey: .autoRenew)) == 1
        }
        nextRenewTime = try? c.decodeIfPresent(String.self, forKey: .nextRenewTime)
        valid = try? c.decodeIfPresent(String.self, forKey: .valid)
    }

    /// ZCode's `isActivePersonalCodingPlan`: a coding product, VALID, in its period.
    var isActiveCodingPlan: Bool {
        let isCoding = [productId, productName].contains { $0?.lowercased().contains("coding") == true }
        return isCoding && status == "VALID" && inCurrentPeriod == true
    }

    /// The active plan, with ZCode's renew-vs-expire rule: an auto-renewing
    /// plan renews on `nextRenewTime`; otherwise it expires then (or at the
    /// end of its `valid` range).
    static func currentPlan(in list: [ZaiSubscription]) -> ZaiPlanInfo? {
        guard let sub = list.first(where: \.isActiveCodingPlan),
              let name = (sub.productName ?? sub.productId)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return nil }
        let next = sub.nextRenewTime.flatMap(dayString)
        if sub.autoRenew, let next { return ZaiPlanInfo(productName: name, renews: true, date: next) }
        let validEnd = sub.valid.flatMap { valid in
            valid.ranges(of: /\d{4}-\d{2}-\d{2}/).last.map { String(valid[$0]) }
        }
        return ZaiPlanInfo(productName: name, renews: false, date: next ?? validEnd)
    }

    private static func dayString(_ text: String) -> String? {
        text.firstMatch(of: /\d{4}-\d{2}-\d{2}/).map { String($0.output) }
    }
}

struct ZaiPlanInfo: Equatable, Sendable {
    var productName: String
    var renews: Bool
    /// "yyyy-MM-dd".
    var date: String?
}

/// `/api/v1/coding-plan/reset/status` — unredeemed reset grants per window.
struct ZaiResetStatus: Decodable, Equatable, Sendable {
    struct Grant: Decodable, Equatable, Sendable {
        /// Unix milliseconds (ZCode compares it with `Date.now()`); plain
        /// seconds are accepted too.
        var expireAt: Double?
        enum CodingKeys: String, CodingKey { case expireAt = "expire_at" }
    }
    var availableFiveHourResets: [Grant]?
    var availableWeekResets: [Grant]?

    enum CodingKeys: String, CodingKey {
        case availableFiveHourResets = "available_five_hour_resets"
        case availableWeekResets = "available_week_resets"
    }
}

/// Pure mapping onto the display model, with the windows ZCode itself shows:
/// the 5-hour pool, the weekly quota and the monthly tool-call quota.
enum ZaiUsageMapper {
    private enum Kind: Int { case session, weekly, other, tools }

    nonisolated static func summarize(_ envelope: ZaiQuotaEnvelope, name: String,
                                      plan: ZaiPlanInfo? = nil, resets: ZaiResetStatus? = nil,
                                      now: Date = Date()) throws -> AccountUsage {
        guard envelope.success != false,
              envelope.code == nil || envelope.code == 0 || envelope.code == 200,
              let data = envelope.data else {
            let message = envelope.msg?.trimmingCharacters(in: .whitespaces) ?? ""
            throw ZCodeUsageError(message.isEmpty ? "Z.ai quota request failed" : "Z.ai: \(message)")
        }

        var out = AccountUsage(provider: .zcode, name: name, status: "ok")
        out.plan = (plan?.productName ?? data.level ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if let plan, let day = plan.date.flatMap(shortDay) {
            out.note = plan.renews ? "renews \(day)" : "expires \(day)"
        }
        if let resets {
            // Unexpired grants only, like ZCode's own reset prompt.
            let expiries = ((resets.availableFiveHourResets ?? []) + (resets.availableWeekResets ?? []))
                .compactMap { grant -> Date? in
                    guard let raw = grant.expireAt, raw.isFinite, raw > 0 else { return nil }
                    return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
                }
                .filter { $0 > now }
            out.resetCredits = expiries.count
            out.resetCreditsExpireAt = isoString(unixMillis: expiries.min().map { $0.timeIntervalSince1970 * 1000 })
        }

        var classified: [(kind: Kind, metric: UsageMetric)] = []
        for (index, limit) in (data.limits ?? []).enumerated() {
            let iso = isoString(unixMillis: limit.nextResetTime)
            var used = limit.percentage
            if used == nil, let current = limit.currentValue, let total = limit.usage, total > 0 {
                used = current / total * 100
            }
            var metric = UsageMetric(id: "\(limit.type.lowercased()):\(index)", label: "",
                                     usedPct: clampPct(used),
                                     resets: UsageFormat.formatReset(iso, now: now), resetsAt: iso)
            let kind: Kind
            switch limit.type {
            case "TIME_LIMIT":
                // ZCode: "Tool calls" — a monthly MCP/tool-call allowance.
                kind = .tools
                metric.label = "TOOLS"
                if let current = limit.currentValue, let total = limit.usage {
                    metric.detail = "\(whole(current)) / \(whole(total)) tool calls"
                }
            default:
                kind = classify(unit: limit.unit, number: limit.number)
                switch kind {
                case .session: metric.label = "SESSION"
                case .weekly:  metric.label = "WEEKLY"
                default:       metric.label = windowLabel(unit: limit.unit, number: limit.number)
                }
            }
            classified.append((kind, metric))
        }
        let ordered = classified.enumerated()
            .sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }
            .map(\.element)
        out.metrics = ordered.map(\.metric)

        // Legacy ESP32 adapter: 5h → session, weekly → weekly, tool calls (or
        // any other window) → model slot.
        if let session = ordered.first(where: { $0.kind == .session })?.metric {
            out.sessionPct = session.usedPct
            out.sessionResets = session.resets
            out.sessionResetsAt = session.resetsAt
        }
        if let weekly = ordered.first(where: { $0.kind == .weekly })?.metric {
            out.weeklyPct = weekly.usedPct
            out.weeklyResets = weekly.resets
            out.weeklyResetsAt = weekly.resetsAt
        }
        if let extra = ordered.first(where: { $0.kind == .tools || $0.kind == .other })?.metric {
            out.modelPct = extra.usedPct
            out.modelResets = extra.resets
            out.modelResetsAt = extra.resetsAt
            out.modelLabel = extra.label
        }
        return out
    }

    private static func classify(unit: Int?, number: Int?) -> Kind {
        let n = number ?? 1
        switch unit {
        case 3 where n <= 6: return .session
        case 6 where n == 1: return .weekly
        default:             return .other
        }
    }

    /// Neutral label from the unit codes ZCode's UI reads; anything else is
    /// just "LIMIT" — never a guessed name.
    nonisolated static func windowLabel(unit: Int?, number: Int?) -> String {
        let n = max(1, number ?? 1)
        switch unit {
        case 3: return "\(n)H"
        case 5: return n == 1 ? "MONTH" : "\(n)MO"
        case 6: return n == 1 ? "WEEKLY" : "\(n)W"
        default: return "LIMIT"
        }
    }

    /// "2026-11-02" → "Nov 2".
    private static func shortDay(_ day: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }

    private static func whole(_ value: Double) -> String {
        value.isFinite && value.magnitude < Double(Int.max) ? String(Int(value.rounded())) : String(value)
    }

    private static func clampPct(_ value: Double?) -> Int {
        guard let value, value.isFinite else { return 0 }
        return min(100, max(0, Int(value.rounded())))
    }

    nonisolated static func isoString(unixMillis: Double?) -> String? {
        guard let unixMillis, unixMillis > 0 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: unixMillis / 1000))
    }
}
