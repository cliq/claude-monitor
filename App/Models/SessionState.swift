import Foundation

enum SessionState: String, Codable, Equatable, CaseIterable {
    case working
    case waiting
    case needsYou
    case finished
}

extension SessionState {
    var displayLabel: String {
        switch self {
        case .working:  return "Working"
        case .waiting:  return "Waiting"
        case .needsYou: return "Needs you"
        case .finished: return "Finished"
        }
    }
}
