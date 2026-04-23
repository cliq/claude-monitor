import SwiftUI

enum SessionState: String, Codable, Equatable, CaseIterable {
    case working
    case waiting
    case needsYou
    case finished
}

extension SessionState {
    /// Tile background color. Keep values in sync with the spec.
    var tileColor: Color {
        switch self {
        case .working:  return Color(red: 0x3B/255, green: 0x82/255, blue: 0xF6/255)
        case .waiting:  return Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)
        case .needsYou: return Color(red: 0xEF/255, green: 0x44/255, blue: 0x44/255)
        case .finished: return Color(red: 0x6B/255, green: 0x72/255, blue: 0x80/255)
        }
    }

    var displayLabel: String {
        switch self {
        case .working:  return "Working"
        case .waiting:  return "Waiting"
        case .needsYou: return "Needs you"
        case .finished: return "Finished"
        }
    }
}
