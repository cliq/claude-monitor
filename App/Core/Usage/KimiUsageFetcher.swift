import Foundation

/// Fetches Kimi Code membership quota from the managed `/usages` endpoint
/// with the OAuth token the Kimi Code CLI keeps in
/// `<home>/credentials/<name>.json`.
///
/// Access tokens live 15 minutes, so the poller has to refresh them — and the
/// refresh token rotates on every refresh. `KimiTokenStore` follows the CLI's
/// own multi-process contract (proper-lockfile `mkdir` lock, re-read after
/// locking, atomic write-back) so Kimi stays logged in; it never writes the
/// revoked tombstone or deletes the file the way the CLI does on a rejected
/// refresh — logging the user out is the CLI's call, not the monitor's.
struct KimiUsageFetcher: UsageFetching {
    var session: URLSession = .shared
    var planCache = KimiUsageFetcher.sharedPlanCache

    /// Membership level from `<base_url>/me`, refreshed hourly.
    static let sharedPlanCache = UsageSideInfoCache<String>()

    func fetch(account: UsageAccountConfig) async throws -> AccountUsage {
        let login = try KimiCodeConfig.resolve(home: URL(fileURLWithPath: account.configDir))
        let store = KimiTokenStore(login: login)
        let accessToken = try await store.freshAccessToken { refreshToken in
            try await KimiOAuth.refresh(refreshToken: refreshToken, oauthHost: login.oauthHost, session: session)
        }

        var req = URLRequest(url: login.baseURL.appendingPathComponent("usages"))
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UsageHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401: throw KimiUsageError("Kimi rejected the stored login — run `kimi login`")
        case 404: throw KimiUsageError("Kimi usage endpoint not available for this login")
        default: throw KimiUsageError("Kimi usage HTTP \(status)")
        }
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let plan = await planCache.value(for: account.configDir, ttl: 3600) { [session] in
            try await Self.fetchPlanName(baseURL: login.baseURL, accessToken: accessToken, session: session)
        }
        return KimiUsageMapper.summarize(response, name: account.name, planName: plan)
    }

    /// The profile also carries personal details (phone, nickname); only the
    /// membership level name is decoded.
    private static func fetchPlanName(baseURL: URL, accessToken: String, session: URLSession) async throws -> String {
        struct Profile: Decodable {
            var userLevelName: String?
            enum CodingKeys: String, CodingKey { case userLevelName = "user_level_name" }
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("me"))
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UsageHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw KimiUsageError("Kimi profile unavailable") }
        return try JSONDecoder().decode(Profile.self, from: data).userLevelName ?? ""
    }
}

struct KimiUsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = String(message.prefix(200)) }
    var errorDescription: String? { message }
}

// MARK: - Config

/// Endpoints and credential slot of one Kimi Code login.
struct KimiCodeLogin: Equatable {
    var home: URL
    var baseURL: URL
    var oauthHost: URL
    /// Token file stem, e.g. `kimi-code-env-0e4f99c69cc27850` (the config's
    /// oauth `key` minus its `oauth/` prefix).
    var credentialName: String

    var credentialsFile: URL {
        home.appendingPathComponent("credentials").appendingPathComponent("\(credentialName).json")
    }
    /// proper-lockfile locks `oauth/<name>` by creating the `oauth/<name>.lock`
    /// directory — the CLI's refresh critical section.
    var lockTarget: URL { home.appendingPathComponent("oauth").appendingPathComponent(credentialName) }
    var lockDir: URL { lockTarget.appendingPathExtension("lock") }
}

/// Reads the managed provider entry out of `<home>/config.toml`. Only the
/// three keys we need are parsed, line by line — not a TOML implementation.
enum KimiCodeConfig {
    static let managedProvider = "managed:kimi-code"
    /// Mainland-China deployment (the CLI's default region).
    static let mainlandBaseURL = "https://api.kimi.com/coding/v1"
    static let mainlandOAuthHost = "https://auth.kimi.com"
    static let globalBaseURL = "https://api.kimi.ai/coding/v1"
    static let globalOAuthHost = "https://auth.kimi.ai"
    /// The slot a mainland login uses when the config names none.
    static let defaultCredentialName = "kimi-code"

    struct Parsed: Equatable {
        var baseURL: String?
        var oauthKey: String?
        var oauthHost: String?
    }

    nonisolated static func parse(toml: String) -> Parsed {
        let providerHeader = "[providers.\"\(managedProvider)\"]"
        let oauthHeader = "[providers.\"\(managedProvider)\".oauth]"
        var section = ""
        var out = Parsed()
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.replacingOccurrences(of: " ", with: "")
                continue
            }
            guard section == providerHeader || section == oauthHeader,
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard let value = quotedValue(line[line.index(after: eq)...]) else { continue }
            switch (section == oauthHeader, key) {
            case (false, "base_url"): out.baseURL = value
            case (true, "key"): out.oauthKey = value
            case (true, "oauth_host"): out.oauthHost = value
            default: break
            }
        }
        return out
    }

    /// Resolves the login the CLI would use: configured hosts first, then the
    /// install-region marker (`<home>/region`), then the mainland defaults.
    static func resolve(home: URL) throws -> KimiCodeLogin {
        let toml = (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let parsed = parse(toml: toml)
        let region = (try? String(contentsOf: home.appendingPathComponent("region"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var name = parsed.oauthKey.map { key in
            key.hasPrefix("oauth/") ? String(key.dropFirst("oauth/".count)) : key
        }
        if name == nil {
            let dir = home.appendingPathComponent("credentials")
            let stems = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(".json".count)) }
            name = stems.count == 1 ? stems[0] : defaultCredentialName
        }
        guard let credentialName = name, isSafeStem(credentialName) else {
            throw KimiUsageError("Kimi config names an invalid credential slot")
        }

        // CLI order: configured host, then the default slot (mainland), then
        // the install marker.
        let global = parsed.oauthHost.map { normalized($0) == globalOAuthHost }
            ?? (parsed.oauthKey != "oauth/\(defaultCredentialName)" && region == "global")
        let host = parsed.oauthHost ?? (global ? globalOAuthHost : mainlandOAuthHost)
        let base = parsed.baseURL ?? (global ? globalBaseURL : mainlandBaseURL)
        guard let oauthHost = httpsURL(host), let baseURL = httpsURL(base) else {
            throw KimiUsageError("Kimi config has a non-HTTPS endpoint")
        }
        return KimiCodeLogin(home: home, baseURL: baseURL, oauthHost: oauthHost,
                             credentialName: credentialName)
    }

    private static func quotedValue(_ raw: Substring) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "\"", let close = trimmed.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
    }

    private static func normalized(_ url: String) -> String {
        var out = url.trimmingCharacters(in: .whitespaces)
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: normalized(string)), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Same rule as the CLI's `FileTokenStorage.pathFor`: a bare file stem.
    private static func isSafeStem(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }
}

// MARK: - Token storage

/// The CLI's token wire format (`tokenToWire`), snake_case on disk.
struct KimiToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix seconds; 0 means "never refresh".
    var expiresAt: Double
    var scope: String
    var tokenType: String
    var expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    init(accessToken: String, refreshToken: String, expiresAt: Double,
         scope: String = "", tokenType: String = "Bearer", expiresIn: Double) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }

    // Lenient like the CLI's `tokenFromWire`: missing fields default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt) ?? 0
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
        expiresIn = try c.decodeIfPresent(Double.self, forKey: .expiresIn) ?? 0
    }

    /// The CLI's `shouldRefreshToken` with its default threshold:
    /// `max(300s, expires_in / 2)` before expiry.
    func needsRefresh(now: Date) -> Bool {
        guard expiresAt > 0 else { return false }
        let threshold = expiresIn > 0 ? max(300, expiresIn * 0.5) : 300
        return expiresAt - now.timeIntervalSince1970 < threshold
    }
}

/// File-backed token access that cooperates with running Kimi CLIs.
struct KimiTokenStore {
    let login: KimiCodeLogin
    var now: () -> Date = Date.init
    /// proper-lockfile's `stale` option as the CLI configures it. Holders
    /// refresh the lock's mtime every `stale / 2`.
    var staleLockAge: TimeInterval = 5

    enum RefreshFailure: Error {
        /// 401/403/`invalid_grant`: the refresh token on disk was rejected.
        case unauthorized
    }

    func load() throws -> KimiToken {
        guard let data = try? Data(contentsOf: login.credentialsFile) else {
            throw KimiUsageError("not logged in to Kimi Code — run `kimi login`")
        }
        guard let token = try? JSONDecoder().decode(KimiToken.self, from: data) else {
            throw KimiUsageError("unreadable Kimi credentials file")
        }
        return token
    }

    /// Atomic replace (temp file + rename), mode 0600, same shape as the CLI.
    func save(_ token: KimiToken) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(token)
        data.append(0x0A)
        let target = login.credentialsFile
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw KimiUsageError("could not write Kimi credentials")
        }
        guard rename(tmp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw KimiUsageError("could not replace Kimi credentials")
        }
    }

    /// Takes the CLI's refresh lock without waiting: `mkdir` succeeds, or a
    /// lock whose mtime is older than `staleLockAge` is reclaimed once.
    /// Returns false while a live holder (a CLI mid-refresh) owns it.
    func acquireLock() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: login.lockTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: login.lockTarget.path) {
            fm.createFile(atPath: login.lockTarget.path, contents: Data())
        }
        if mkdir(login.lockDir.path, 0o777) == 0 { return true }
        guard errno == EEXIST,
              let mtime = (try? fm.attributesOfItem(atPath: login.lockDir.path))?[.modificationDate] as? Date,
              now().timeIntervalSince(mtime) > staleLockAge else { return false }
        rmdir(login.lockDir.path)
        return mkdir(login.lockDir.path, 0o777) == 0
    }

    /// Bumps the lock's mtime so CLIs don't treat a slow refresh as stale.
    func touchLock() {
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: login.lockDir.path)
    }

    func releaseLock() {
        rmdir(login.lockDir.path)
    }

    /// A usable access token, refreshing (and writing back) when inside the
    /// CLI's refresh threshold.
    func freshAccessToken(refresh: (String) async throws -> KimiToken) async throws -> String {
        let initial = try validToken(try load())
        guard initial.needsRefresh(now: now()) else { return initial.accessToken }

        guard acquireLock() else {
            // A CLI is refreshing right now; its result lands on disk shortly.
            if initial.expiresAt > now().timeIntervalSince1970 { return initial.accessToken }
            throw KimiUsageError("Kimi token refresh in progress elsewhere — retrying next poll")
        }
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(staleLockAge / 2 * 1_000_000_000))
                touchLock()
            }
        }
        defer {
            heartbeat.cancel()
            releaseLock()
        }

        // Another process may have rotated the token while we waited.
        let current = try validToken(try load())
        guard current.needsRefresh(now: now()) else { return current.accessToken }
        guard !current.refreshToken.isEmpty else {
            throw KimiUsageError("Kimi login has no refresh token — run `kimi login`")
        }
        do {
            let refreshed = try await refresh(current.refreshToken)
            try save(refreshed)
            return refreshed.accessToken
        } catch RefreshFailure.unauthorized {
            // A lock-less refresher may have won the rotation; adopt its token.
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let recovery = try? load(), !recovery.accessToken.isEmpty,
               recovery.refreshToken != current.refreshToken {
                return recovery.accessToken
            }
            throw KimiUsageError("Kimi rejected the stored login — run `kimi login`")
        }
    }

    private func validToken(_ token: KimiToken) throws -> KimiToken {
        guard !token.accessToken.isEmpty else {
            throw KimiUsageError("Kimi login was revoked — run `kimi login`")
        }
        return token
    }
}

// MARK: - OAuth refresh

enum KimiOAuth {
    /// Kimi Code CLI's public OAuth client id (shared across regions).
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func refresh(refreshToken: String, oauthHost: URL, session: URLSession) async throws -> KimiToken {
        var req = URLRequest(url: oauthHost.appendingPathComponent("api/oauth/token"))
        req.httpMethod = "POST"
        // Short: the refresh runs under the CLI's lock.
        req.timeoutInterval = 10
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UsageHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = formBody([
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return try token(status: status, json: json, now: Date())
    }

    /// Mirrors the CLI's `refreshAccessToken` / `tokenFromResponse`.
    nonisolated static func token(status: Int, json: [String: Any], now: Date) throws -> KimiToken {
        let errorCode = json["error"] as? String ?? ""
        if status == 401 || status == 403 || errorCode == "invalid_grant" {
            throw KimiTokenStore.RefreshFailure.unauthorized
        }
        guard status == 200,
              let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
                ?? (json["expires_in"] as? String).flatMap(Double.init),
              expiresIn > 0 else {
            throw KimiUsageError("Kimi token refresh failed (HTTP \(status))")
        }
        return KimiToken(accessToken: access,
                         refreshToken: refresh,
                         expiresAt: (now.timeIntervalSince1970 + expiresIn).rounded(.down),
                         scope: json["scope"] as? String ?? "",
                         tokenType: json["token_type"] as? String ?? "Bearer",
                         expiresIn: expiresIn)
    }

    private static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }
}

// MARK: - Response mapping

/// `GET <base_url>/usages`. Ratios and amounts may arrive as numbers or
/// numeric strings; anything unparseable is dropped like the CLI does.
struct KimiUsagesResponse: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        var usedRatio: Double?
        var resetTime: String?

        enum CodingKeys: String, CodingKey {
            case usedRatio = "used_ratio"
            case resetTime = "reset_time"
        }

        init(usedRatio: Double?, resetTime: String?) {
            self.usedRatio = usedRatio
            self.resetTime = resetTime
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedRatio = c.flexibleDouble(.usedRatio)
            let reset = try? c.decodeIfPresent(String.self, forKey: .resetTime)
            resetTime = (reset?.isEmpty ?? true) ? nil : reset
        }
    }

    struct Usages: Decodable, Equatable {
        var limit5h: Entry?
        var limit7d: Entry?
        var monthTotal: Entry?
        var monthCode: Entry?

        enum CodingKeys: String, CodingKey {
            case limit5h = "limit_5h"
            case limit7d = "limit_7d"
            case monthTotal = "limit_month_total"
            case monthCode = "limit_month_code"
        }
    }

    struct Money: Decodable, Equatable {
        var currency: String?
    }

    struct BoosterWallet: Decodable, Equatable {
        struct Balance: Decodable, Equatable {
            var type: String?
            var amountLeft: Double?

            enum CodingKeys: String, CodingKey { case type, amountLeft }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try? c.decodeIfPresent(String.self, forKey: .type)
                amountLeft = c.flexibleDouble(.amountLeft)
            }
        }
        var balance: Balance?
        var monthlyChargeLimit: Money?
        var monthlyUsed: Money?
    }

    var usages: Usages?
    var boosterWallet: BoosterWallet?

    enum CodingKeys: String, CodingKey { case usages, boosterWallet }

    init(usages: Usages?, boosterWallet: BoosterWallet? = nil) {
        self.usages = usages
        self.boosterWallet = boosterWallet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usages = try? c.decodeIfPresent(Usages.self, forKey: .usages)
        boosterWallet = try? c.decodeIfPresent(BoosterWallet.self, forKey: .boosterWallet)
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value.isFinite ? value : nil }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }
}

/// Pure mapping onto the display model, in the order Kimi's own `/usage`
/// renders it: 5h, weekly, monthly (with its code share in the detail).
enum KimiUsageMapper {
    /// The booster wallet's fixed-point unit (CLI `FIXED_POINT_CENTS`).
    private static let fixedPointPerCent: Double = 1_000_000

    /// `planName` is the profile's `user_level_name` (e.g. "Plus").
    nonisolated static func summarize(_ response: KimiUsagesResponse, name: String,
                                      planName: String? = nil, now: Date = Date()) -> AccountUsage {
        var out = AccountUsage(provider: .kimi, name: name, status: "ok")
        out.plan = (planName ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let usages = response.usages

        func metric(_ id: String, _ label: String, _ entry: KimiUsagesResponse.Entry?) -> UsageMetric? {
            guard let entry, let ratio = entry.usedRatio else { return nil }
            let iso = normalizedISO(entry.resetTime)
            return UsageMetric(id: id, label: label, usedPct: pct(ratio),
                               resets: UsageFormat.formatReset(iso, now: now), resetsAt: iso)
        }

        let session = metric("5h", "SESSION", usages?.limit5h)
        let weekly = metric("7d", "WEEKLY", usages?.limit7d)
        var month = metric("month", "MONTH", usages?.monthTotal)
        if month != nil, let total = usages?.monthTotal?.usedRatio {
            let code = clampRatio(usages?.monthCode?.usedRatio ?? 0)
            let kimi = clampRatio(((total - code) * 1_000_000).rounded() / 1_000_000)
            month?.detail = "code \(pct(code))% · kimi \(pct(kimi))%"
        }
        out.metrics = [session, weekly, month].compactMap { $0 }

        // Legacy ESP32 adapter: 5h → session, 7d → weekly, month → model slot.
        if let session {
            out.sessionPct = session.usedPct
            out.sessionResets = session.resets
            out.sessionResetsAt = session.resetsAt
        }
        if let weekly {
            out.weeklyPct = weekly.usedPct
            out.weeklyResets = weekly.resets
            out.weeklyResetsAt = weekly.resetsAt
        }
        if let month {
            out.modelPct = month.usedPct
            out.modelResets = month.resets
            out.modelResetsAt = month.resetsAt
            out.modelLabel = month.label
        }

        if let wallet = response.boosterWallet, wallet.balance?.type == "BOOSTER",
           let left = wallet.balance?.amountLeft, left > 0 {
            let currency = [wallet.monthlyChargeLimit?.currency, wallet.monthlyUsed?.currency]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "USD"
            let amount = String(format: "%.2f", (left / fixedPointPerCent).rounded() / 100)
            out.note = currency == "USD" ? "booster $\(amount)" : "booster \(amount) \(currency)"
        }
        return out
    }

    private static func clampRatio(_ ratio: Double) -> Double {
        ratio.isFinite ? min(1, max(0, ratio)) : 0
    }

    private static func pct(_ ratio: Double) -> Int {
        Int((clampRatio(ratio) * 100).rounded())
    }

    /// Reset times may carry fractional seconds; store plain internet time.
    nonisolated static func normalizedISO(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: iso)
        }
        guard let date else { return nil }
        let out = ISO8601DateFormatter()
        out.formatOptions = [.withInternetDateTime]
        return out.string(from: date)
    }
}
