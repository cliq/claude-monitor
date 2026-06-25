// App/Models/Session.swift
import Foundation

struct Session: Identifiable, Equatable {
    let id: String                  // session_id from Claude Code
    var cwd: String
    var tty: String
    var pid: Int32
    var state: SessionState
    var enteredStateAt: Date        // when the current state was entered (drives elapsed time)
    var lastPromptPreview: String?  // sticks between UserPromptSubmit events
    var backgroundTaskCount: Int = 0  // active background tasks while .backgroundWorking

    /// Human-readable project name = last path component of cwd.
    var projectName: String {
        (cwd as NSString).lastPathComponent
    }
}
