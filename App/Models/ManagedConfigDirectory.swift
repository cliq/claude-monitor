// App/Models/ManagedConfigDirectory.swift
import Foundation

enum HookInstallStatus: String, Codable, Equatable {
    case notInstalled
    case installed
    case outdated        // an older hook schema version is installed
    case modifiedExternally  // the managed block was hand-edited
}

struct ManagedConfigDirectory: Identifiable, Codable, Equatable {
    /// The path is the identity.
    var id: String { url.path }
    var url: URL
    var status: HookInstallStatus
    var installedVersion: Int   // 0 = none
}
