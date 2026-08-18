// App/Core/Terminal/OrcaProvider.swift
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Orca (https://onorca.dev) is an Electron agent IDE with embedded terminals.
/// It has no AppleScript dictionary, so this provider works differently from
/// the others: Orca exports `TERM_PROGRAM=Orca` and `ORCA_TERMINAL_HANDLE`
/// into every pty it spawns, and its bundled CLI (`orca terminal switch
/// --terminal <handle>`) selects that tab inside the app over a local socket.
/// We read the Claude process's environment with `ps eww`, extract the handle,
/// ask the CLI to switch, then activate the app ourselves — `terminal switch`
/// deliberately never raises the Orca window.
final class OrcaProvider: TerminalProvider {
    let displayName = "Orca"
    let bundleID = "com.stablyai.orca"

    /// Runs `executable` with `arguments`; returns exit status and stdout,
    /// or nil if the process couldn't launch or timed out.
    typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String)?

    private let runCommand: CommandRunner
    private let cliPathResolver: () -> String?
    private let activateApp: () -> Void

    init(runCommand: @escaping CommandRunner = OrcaProvider.runProcess,
         cliPathResolver: (() -> String?)? = nil,
         activateApp: (() -> Void)? = nil) {
        self.runCommand = runCommand
        self.cliPathResolver = cliPathResolver ?? { OrcaProvider.locateCLI() }
        self.activateApp = activateApp ?? { OrcaProvider.activateOrca() }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        // Orca doesn't expose sessions by tty; the handle in the process
        // environment is the only external address for a pane.
        guard let ps = runCommand("/bin/ps", ["eww", "-o", "command=", "-p", String(expectedPid)]),
              ps.status == 0 else {
            return .noSuchTab
        }
        guard let handle = Self.terminalHandle(fromEnvironmentDump: ps.stdout) else {
            return .noSuchTab
        }
        guard let cli = cliPathResolver() else {
            return .scriptError("Orca CLI not found")
        }
        let switched = runCommand(cli, ["terminal", "switch", "--terminal", handle, "--json"])
        if switched?.status != 0 {
            // Handles go stale across Orca restarts (`terminal_handle_stale`).
            // The env proved the session lives in Orca, so no other provider
            // can match — bring the app forward as a best effort and stop.
            NSLog("OrcaProvider: terminal switch failed for handle \(handle)")
        }
        activateApp()
        return .focused
    }

    /// Extracts `ORCA_TERMINAL_HANDLE` from a `ps eww` command+environment
    /// dump, but only when the environment also claims `TERM_PROGRAM=Orca`.
    /// Values are space-delimited in `ps` output; the handle (`term_<uuid>`)
    /// never contains spaces.
    static func terminalHandle(fromEnvironmentDump dump: String) -> String? {
        guard dump.contains("TERM_PROGRAM=Orca") else { return nil }
        guard let range = dump.range(of: "ORCA_TERMINAL_HANDLE=") else { return nil }
        let value = dump[range.upperBound...]
            .prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    /// The CLI ships inside the app bundle; the `/usr/local/bin` and
    /// `~/.local/bin` symlinks are what Orca's own installer creates.
    private static func locateCLI() -> String? {
        var candidates: [String] = []
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca") {
            candidates.append(appURL.appendingPathComponent("Contents/Resources/bin/orca").path)
        }
        candidates.append("/usr/local/bin/orca")
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/orca"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func activateOrca() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca")
            .first?
            .activate()
    }

    /// Synchronous run with a hard timeout so a wedged CLI (its socket waits
    /// on the app) can never hang the click handler.
    static func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout off-thread: readDataToEndOfFile unblocks at EOF, which
        // terminate() forces on timeout by killing the writer.
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if readDone.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            _ = readDone.wait(timeout: .now() + 1)
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }

    private final class DataBox {
        var data = Data()
    }
}
