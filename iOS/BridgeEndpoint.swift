// iOS/BridgeEndpoint.swift
import Foundation
import Network

/// Which Mac the app reads usage from: a Bonjour service the Mac's
/// `UsageBridgeServer` advertises, or an address typed by hand.
enum BridgeEndpoint: Codable, Hashable {
    case bonjour(name: String)
    case manual(host: String, port: UInt16)

    /// Must match `UsageBridgeServer.bonjourServiceType` on the Mac and
    /// `NSBonjourServices` in the iOS Info.plist.
    static let serviceType = "_claudemonitor._tcp"
    /// Mirrors `UsageBridgeServer.defaultPort`.
    static let defaultPort: UInt16 = 8737

    var displayName: String {
        switch self {
        case .bonjour(let name): return name
        case .manual(let host, let port): return port == Self.defaultPort ? host : "\(host):\(port)"
        }
    }

    var networkEndpoint: NWEndpoint {
        switch self {
        case .bonjour(let name):
            return .service(name: name, type: Self.serviceType, domain: "local.", interface: nil)
        case .manual(let host, let port):
            return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8737)
        }
    }

    /// Parses "host", "host:port" or "http://host:port/…" as typed in the
    /// manual field. Nil for blank input or an out-of-range port.
    static func manual(from input: String) -> BridgeEndpoint? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return .manual(host: text, port: defaultPort)
        case 2:
            guard !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
            return .manual(host: String(parts[0]), port: port)
        default:
            return nil // IPv6 literals aren't supported; use the Mac's .local name
        }
    }
}

/// The selected Mac, persisted where both the app and the widget extension
/// can read it: the App Group's defaults (`AppGroupIdentifier` Info.plist
/// key). Falls back to standard defaults when the group is unavailable
/// (unsigned builds) — the app keeps working, only the widget can't see it.
enum BridgeEndpointStore {
    static let key = "bridgeEndpoint"

    static var sharedDefaults: UserDefaults {
        let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        guard let id, !id.isEmpty, let suite = UserDefaults(suiteName: id) else { return .standard }
        return suite
    }

    static func load(from defaults: UserDefaults = sharedDefaults) -> BridgeEndpoint? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BridgeEndpoint.self, from: $0) }
    }

    static func save(_ endpoint: BridgeEndpoint?, to defaults: UserDefaults = sharedDefaults) {
        if let endpoint, let data = try? JSONEncoder().encode(endpoint) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The one account the Home Screen widget shows, picked in the app from the
/// accounts it lists (`/panel`). Nil keeps the Mac's "Widget · ESP32"
/// selection (`/usage`). Stored as `AccountUsage.id` — provider-qualified,
/// so same-named Claude and Codex accounts don't collide.
enum WidgetAccountStore {
    static let key = "widgetAccountID"

    static func load(from defaults: UserDefaults = BridgeEndpointStore.sharedDefaults) -> String? {
        defaults.string(forKey: key)
    }

    static func save(_ id: String?, to defaults: UserDefaults = BridgeEndpointStore.sharedDefaults) {
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The bridge path the widget reads: every account when one is picked
    /// (it may not be checked for external displays on the Mac), otherwise
    /// the Mac's own selection.
    static func path(for id: String?) -> String {
        id == nil ? "/usage" : "/panel"
    }

    /// `snapshot` narrowed to the picked account. Unchanged when nothing is
    /// picked, or when the account is gone from the Mac (renamed/removed) —
    /// every account beats an empty widget.
    static func filter(_ snapshot: UsageSnapshot, to id: String?) -> UsageSnapshot {
        guard let id else { return snapshot }
        let picked = snapshot.accounts.filter { $0.id == id }
        guard !picked.isEmpty else { return snapshot }
        var filtered = snapshot
        filtered.accounts = picked
        return filtered
    }
}
