import Foundation

/// Shared on-disk hand-off of the latest `UsageSnapshot` between the app and
/// the widget extension via the App Group container. Foundation-only (no
/// AppKit, no keychain/discovery deps) so this file can compile into both
/// targets.
enum UsageSnapshotStore {
    static let widgetKind = "UsageWidget"
    static let fileName = "usage-snapshot.json"

    /// Resolves the App Group container directory. `groupID` is for tests;
    /// production callers rely on the `AppGroupIdentifier` Info.plist key
    /// (present in both the app and widget targets). Returns nil when the ID
    /// is missing/empty, or malformed (e.g. a leading "." because
    /// `DEVELOPMENT_TEAM` is empty in an unsigned local build).
    static func containerURL(groupID: String? = nil) -> URL? {
        let id = groupID ?? (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
        guard let id, !id.isEmpty, !id.hasPrefix(".") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Writes `snapshot` atomically by writing to a sibling `.tmp` and
    /// renaming. `dir` defaults to `containerURL()`; a nil dir (group
    /// unavailable) is a silent no-op — the app must work without the group.
    /// All errors are swallowed for the same reason.
    static func write(_ snapshot: UsageSnapshot, to dir: URL? = nil) {
        guard let dir = dir ?? containerURL() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let destination = dir.appendingPathComponent(fileName)
            let tmp = destination.appendingPathExtension("tmp")
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: tmp, options: .atomic)

            // Posix rename is atomic on the same volume.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: destination)
            }
        } catch {
            // Never crash or throw — the app must work without the group.
        }
    }

    /// Reads back the last-written snapshot. Nil `dir`, or a missing/corrupt
    /// file, returns nil.
    static func read(from dir: URL? = nil) -> UsageSnapshot? {
        guard let dir = dir ?? containerURL() else { return nil }
        let destination = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: destination) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// Removes the snapshot file, ignoring errors (missing file included).
    static func clear(in dir: URL? = nil) {
        guard let dir = dir ?? containerURL() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }
}
