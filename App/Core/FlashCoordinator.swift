import Foundation

struct FlashCoordinator {
    private var previousStates: [String: SessionState] = [:]
    private var flashIds: [String: UUID] = [:]

    /// Returns the current `sessionId → flashId` map. IDs only change on qualifying transitions.
    mutating func update(sessions: [Session]) -> [String: UUID] {
        for s in sessions {
            defer { previousStates[s.id] = s.state }
            guard let prev = previousStates[s.id] else { continue }  // first sighting = no flash
            if shouldFlash(from: prev, to: s.state) {
                flashIds[s.id] = UUID()
            }
        }
        // Drop entries for sessions that went away.
        let live = Set(sessions.map(\.id))
        previousStates = previousStates.filter { live.contains($0.key) }
        flashIds = flashIds.filter { live.contains($0.key) }
        return flashIds
    }

    private func shouldFlash(from old: SessionState, to new: SessionState) -> Bool {
        if old == new { return false }
        if new == .waiting  { return true }
        if new == .needsYou { return true }
        if old == .needsYou && new == .working { return true }
        return false
    }
}
