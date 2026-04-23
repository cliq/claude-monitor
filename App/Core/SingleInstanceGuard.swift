import Foundation
import Darwin

enum SingleInstanceGuardResult: Equatable {
    case acquired
    case alreadyRunning(pid_t)
}

enum SingleInstanceGuard {
    static func acquire(at path: URL) -> SingleInstanceGuardResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: path.path),
           let body = try? String(contentsOf: path, encoding: .utf8),
           let pid = pid_t(body.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           kill(pid, 0) == 0  // signal 0 = existence check
        {
            return .alreadyRunning(pid)
        }
        // Take ownership.
        let our = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? our.write(to: path, atomically: true, encoding: .utf8)
        return .acquired
    }

    static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/pid")
    }
}
