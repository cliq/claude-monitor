import Foundation

protocol Clock {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

/// Test double: advances only when `advance(by:)` is called.
final class FakeClock: Clock {
    private var current: Date
    init(start: Date = Date(timeIntervalSince1970: 1_745_438_400)) {
        self.current = start
    }
    func now() -> Date { current }
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
