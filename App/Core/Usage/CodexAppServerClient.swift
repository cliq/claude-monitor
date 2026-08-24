import Foundation

// MARK: - Errors

/// User-visible error taxonomy for Codex usage collection. Descriptions are
/// deliberately short and non-sensitive — they end up on the panel/widget and
/// in the ESP32 JSON.
enum CodexUsageError: Error, Equatable, LocalizedError {
    case executableNotFound
    case methodUnavailable
    case apiKeyAuth
    case notAuthenticated
    case timeout
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Codex CLI not found"
        case .methodUnavailable:  return "Update Codex to track usage"
        case .apiKeyAuth:         return "ChatGPT login required for plan limits"
        case .notAuthenticated:   return "Sign in to Codex again"
        case .timeout, .processFailed: return "Codex usage request failed"
        }
    }
}

// MARK: - Wire models (app-server `account/rateLimits/read` result)

/// All fields optional by design: Codex evolves independently of this app, so
/// missing/renamed members must degrade to "metric omitted", never a decode
/// failure.
struct CodexRateLimitWindow: Decodable, Equatable {
    var usedPercent: Double?
    var windowDurationMins: Double?
    var resetsAt: Double? // unix seconds
}

struct CodexIndividualLimit: Decodable, Equatable {
    var limit: String?
    var used: String?
    var remainingPercent: Double?
    var resetsAt: Double? // unix seconds

    init(limit: String? = nil, used: String? = nil,
         remainingPercent: Double? = nil, resetsAt: Double? = nil) {
        self.limit = limit
        self.used = used
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey { case limit, used, remainingPercent, resetsAt }

    // `limit`/`used` arrive as strings today but are amounts — accept numbers too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = Self.stringOrNumber(c, .limit)
        used = Self.stringOrNumber(c, .used)
        remainingPercent = (try? c.decodeIfPresent(Double.self, forKey: .remainingPercent)) ?? nil
        resetsAt = (try? c.decodeIfPresent(Double.self, forKey: .resetsAt)) ?? nil
    }

    private static func stringOrNumber(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
}

struct CodexRateLimitSnapshot: Decodable, Equatable {
    var limitId: String?
    var limitName: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var individualLimit: CodexIndividualLimit?
    var spendControlReached: Bool?
    var planType: String?
    var rateLimitReachedType: String?
}

struct CodexRateLimitsResult: Decodable, Equatable {
    var rateLimits: CodexRateLimitSnapshot?
    var rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

// MARK: - JSONL response accumulation

/// Feeds raw stdout chunks, yields the correlated response for `requestID`.
/// Tolerates fragmented lines, multiple lines per chunk, interleaved
/// notifications (`remoteControl/status/changed`, …), other response IDs, and
/// malformed lines.
final class CodexResponseAccumulator {
    enum Outcome: Equatable {
        case pending
        case success(CodexRateLimitsResult)
        case failure(CodexUsageError)
    }

    private var buffer = Data()
    private let requestID: Int

    init(requestID: Int) {
        self.requestID = requestID
    }

    func feed(_ chunk: Data) -> Outcome {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let outcome = process(line: line) { return outcome }
        }
        return .pending
    }

    private func process(line: Data) -> Outcome? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = obj["id"] as? Int, id == requestID else {
            return nil // notification, another request's response, or noise
        }
        if let error = obj["error"] as? [String: Any] {
            return .failure(Self.mapRPCError(message: error["message"] as? String ?? ""))
        }
        guard let result = obj["result"],
              JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result),
              let decoded = try? JSONDecoder().decode(CodexRateLimitsResult.self, from: data) else {
            return .failure(.processFailed("unexpected rate-limit response shape"))
        }
        return .success(decoded)
    }

    /// Best-effort mapping of app-server error messages onto the actionable
    /// cases; anything unrecognized falls through to a capped generic error.
    static func mapRPCError(message: String) -> CodexUsageError {
        let m = message.lowercased()
        if m.contains("method") && (m.contains("not found") || m.contains("unknown") || m.contains("not supported")) {
            return .methodUnavailable
        }
        if m.contains("api key") || m.contains("apikey") || m.contains("api-key") {
            return .apiKeyAuth
        }
        if m.contains("unauthorized") || m.contains("logged out") || m.contains("not logged in")
            || m.contains("login") || m.contains("auth") {
            return .notAuthenticated
        }
        return .processFailed(String(message.prefix(200)))
    }
}

// MARK: - Client

/// Short-lived `codex app-server` session: launch, handshake, read
/// `account/rateLimits/read`, terminate. The app server owns authentication
/// and token refresh — this app never reads or writes Codex credentials.
struct CodexAppServerClient {
    static let requestID = 1

    var timeout: TimeInterval = 10

    func fetchRateLimits(codexHome: String) async throws -> CodexRateLimitsResult {
        guard let executable = Self.resolveExecutable() else {
            throw CodexUsageError.executableNotFound
        }
        let timeout = self.timeout
        return try await Task.detached(priority: .utility) {
            try Self.run(executable: executable, codexHome: codexHome, timeout: timeout)
        }.value
    }

    // MARK: Process plumbing (blocking; runs on a detached task)

    private static func run(executable: String, codexHome: String,
                            timeout: TimeInterval) throws -> CodexRateLimitsResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        process.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Capped stderr capture — never log or surface it wholesale.
        let stderrBuffer = CappedBuffer(cap: 2048)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrBuffer.append(data) }
        }

        try process.run()

        let timedOut = AtomicFlag()
        let watchdog = DispatchWorkItem {
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let stdinHandle = stdinPipe.fileHandleForWriting
        defer {
            watchdog.cancel()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinHandle.close()
            if process.isRunning { process.terminate() }
        }

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        // The wire form intentionally omits the JSON-RPC `jsonrpc` member.
        let requests = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"claude_monitor","title":"Claude Monitor","version":"\#(version)"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":\#(requestID)}"#,
        ]
        for request in requests {
            try? stdinHandle.write(contentsOf: Data((request + "\n").utf8))
        }
        // Keep stdin open until we're done — the server treats EOF as shutdown.

        let accumulator = CodexResponseAccumulator(requestID: requestID)
        let stdout = stdoutPipe.fileHandleForReading
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty { break } // EOF: process exited or was terminated
            switch accumulator.feed(chunk) {
            case .pending:
                continue
            case .success(let result):
                return result
            case .failure(let error):
                throw error
            }
        }
        if timedOut.isSet { throw CodexUsageError.timeout }
        let stderrText = stderrBuffer.lastLine(maxChars: 160)
        throw CodexUsageError.processFailed(stderrText.isEmpty ? "codex app-server exited" : stderrText)
    }

    // MARK: Executable discovery

    /// GUI apps get a minimal PATH; check it first, then common install
    /// locations, then a login-shell lookup as a bounded last resort. Never
    /// hardcode a versioned cask path.
    static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        loginShellFallback: () -> String? = { loginShellLookup() }
    ) -> String? {
        var candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/codex" }
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
        ]
        if let found = candidates.first(where: isExecutable) { return found }
        return loginShellFallback()
    }

    private static func loginShellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v codex"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}

// MARK: - Small thread-safe helpers

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < cap else { return }
        data.append(chunk.prefix(cap - data.count))
    }

    func lastLine(maxChars: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(data: data, encoding: .utf8) ?? ""
        let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return String((line ?? "").prefix(maxChars))
    }
}
