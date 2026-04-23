import Foundation

struct PortFileWriter {
    let destination: URL

    /// Writes `<port>\n` atomically by writing to a sibling `.tmp` and renaming.
    func write(port: UInt16) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = destination.appendingPathExtension("tmp")
        let data = "\(port)\n".data(using: .utf8)!
        try data.write(to: tmp, options: .atomic)

        // Posix rename is atomic on the same volume.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }

    /// Default location: `~/.claude-monitor/port`.
    static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/port")
    }
}
