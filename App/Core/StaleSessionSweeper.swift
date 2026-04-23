// App/Core/StaleSessionSweeper.swift
import Foundation
import Darwin

final class StaleSessionSweeper {
    private let store: SessionStore
    private var timer: Timer?
    private let interval: TimeInterval

    init(store: SessionStore, interval: TimeInterval = 60) {
        self.store = store
        self.interval = interval
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sweep() {
        for session in store.orderedSessions {
            guard session.state != .finished else { continue }
            if kill(session.pid, 0) != 0 {   // process gone
                store.markFinished(sessionId: session.id)
            }
        }
    }
}
