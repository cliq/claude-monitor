// App/Core/UpdateChecker.swift
import Foundation

/// Checks GitHub Releases for a newer version at launch and once a day.
/// Passive by design: failures (offline, rate-limited, malformed) are silent
/// and never block anything — the only output is `availableUpdate`, which the
/// menu bar and the General settings tab render. Distribution is the GitHub
/// releases page; the app never downloads or installs anything itself.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Update: Equatable {
        let version: String
        let url: URL
    }

    enum CheckOutcome: Equatable {
        case upToDate
        case updateAvailable(String)
        case failed
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/cliq/claude-monitor/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var availableUpdate: Update?
    @Published private(set) var lastOutcome: CheckOutcome?
    @Published private(set) var lastCheckedAt: Date?

    private let currentVersion: String
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private var timer: Timer?
    /// GitHub returns 304 with no body when the release list hasn't changed
    /// since the ETag'd response — daily re-checks are free on their end.
    private var etag: String?

    /// `nonisolated` so the eager `AppDelegate` property initializer can build
    /// it; only immutable values are assigned here.
    nonisolated init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                     fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    func start() {
        guard timer == nil else { return }
        Task { await self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func checkNow() {
        Task { await self.check() }
    }

    func check() async {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("claude-monitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        guard let (data, response) = try? await fetch(request),
              let http = response as? HTTPURLResponse else {
            lastOutcome = .failed
            lastCheckedAt = Date()
            return
        }
        lastCheckedAt = Date()

        if http.statusCode == 304 {
            // Nothing changed upstream; keep whatever we last concluded.
            lastOutcome = availableUpdate.map { .updateAvailable($0.version) } ?? .upToDate
            return
        }
        guard http.statusCode == 200, let release = Self.parseLatestRelease(data) else {
            lastOutcome = .failed
            return
        }
        etag = http.value(forHTTPHeaderField: "ETag")

        if Self.isNewer(release.version, than: currentVersion) {
            availableUpdate = release
            lastOutcome = .updateAvailable(release.version)
        } else {
            availableUpdate = nil
            lastOutcome = .upToDate
        }
    }

    // MARK: Pure helpers (unit-testable)

    /// Extracts version + release-page URL from a GitHub `releases/latest`
    /// response. `/latest` already excludes drafts and prereleases.
    nonisolated static func parseLatestRelease(_ data: Data) -> Update? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlString = obj["html_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }
        return Update(version: version, url: url)
    }

    /// Numeric dot-component comparison, tolerant of a leading "v" and of
    /// suffixed components ("1.5.0-beta" compares as 1.5.0). Missing
    /// components count as 0, so "1.5" == "1.5.0".
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var s = Substring(s)
            if s.first == "v" || s.first == "V" { s = s.dropFirst() }
            return s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
