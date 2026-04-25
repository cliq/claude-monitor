// App/Models/SessionStateColor.swift
import AppKit

/// Single-source-of-truth state→color mapping. Used by both the status-bar
/// aggregate dot (one color per "winning" state across all sessions) and the
/// per-session dot in the menu-bar dropdown when in menu mode.
enum SessionStateColor {
    static func nsColor(for state: SessionState) -> NSColor {
        switch state {
        case .needsYou: return NSColor(red: 0xEF/255, green: 0x44/255, blue: 0x44/255, alpha: 1)
        case .waiting:  return NSColor(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255, alpha: 1)
        case .working:  return NSColor(red: 0x3B/255, green: 0x82/255, blue: 0xF6/255, alpha: 1)
        case .finished: return NSColor(red: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
        }
    }
}
