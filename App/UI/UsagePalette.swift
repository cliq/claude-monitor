// App/UI/UsagePalette.swift
import SwiftUI

/// Same palette and layout as the ESP32 desk panel (480x480 design), so the
/// in-app view and the external display read identically. Distinct from
/// `Palette` (session tile colors) — these are the usage panel's fixed colors.
enum UsagePalette {
    static let bg = RGB(0x14110D).color
    static let statusBg = RGB(0x0F0D0A).color
    static let line = RGB(0x241F19).color
    static let text = RGB(0xEDE6DB).color
    static let muted = RGB(0x6E6558).color
    static let reset = RGB(0x8A8072).color
    static let idle = RGB(0x55503F).color
    static let name = RGB(0xD97757).color
    static let sand = RGB(0xC9BFAF).color
    static let warn = RGB(0xE3A455).color
    static let crit = RGB(0xE25A3F).color
    static let track = RGB(0x262119).color
    static let okDot = RGB(0x8FAE6E).color
}
