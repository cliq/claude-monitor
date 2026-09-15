import Foundation

/// Stop hooks carry a snapshot of running tasks. Claude can later cancel a shell
/// from its task UI without another hook, but records the result in its transcript.
final class BackgroundTaskReconciler {
    private let store: SessionStore
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.cliqconsulting.claudemonitor.background-tasks",
                                      qos: .utility)
    // Accessed only on queue. Each reader tails one transcript incrementally.
    private var readers: [String: BackgroundTaskTranscriptReader] = [:]
    private var timer: Timer?
    private var pending = false
    private var generation = 0

    init(store: SessionStore, interval: TimeInterval = 5) {
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
        generation += 1
        pending = false
    }

    func sweep(completion: @escaping () -> Void = {}) {
        guard !pending else { completion(); return }
        let sessions = store.orderedSessions.filter {
            $0.provider == .claude && $0.state == .backgroundWorking
                && !$0.backgroundTaskIDs.isEmpty && $0.transcriptPath != nil
        }
        pending = true
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            let ids = Set(sessions.map(\.id))
            self.readers = self.readers.filter { ids.contains($0.key) }
            var results: [(String, String, Set<String>)] = []
            for session in sessions {
                guard let path = session.transcriptPath else { continue }
                let reader: BackgroundTaskTranscriptReader
                if let existing = self.readers[session.id], existing.path == path {
                    reader = existing
                } else {
                    reader = BackgroundTaskTranscriptReader(sessionId: session.id, path: path)
                    self.readers[session.id] = reader
                }
                // Missing/unreadable transcripts are not evidence that work ended.
                if let completed = try? reader.readCompletedTaskIDs() {
                    results.append((session.id, path, completed))
                }
            }
            let completedResults = results
            DispatchQueue.main.async { [weak self] in
                defer { completion() }
                guard let self, self.generation == generation else { return }
                self.pending = false
                for (id, path, completed) in completedResults {
                    self.store.completeBackgroundTasks(sessionId: id, transcriptPath: path,
                                                       taskIDs: completed)
                }
            }
        }
    }
}

/// Reads only structured task notifications queued by Claude, never assistant prose,
/// tool output, or user messages that happen to mention a task. Keep partial JSONL
/// records until the next read, and bound memory when tool output has very long lines.
final class BackgroundTaskTranscriptReader {
    let path: String
    private let sessionId: String
    private var offset: UInt64 = 0
    private var fileNumber: NSNumber?
    private var partial = Data()
    private var skippingLongLine = false
    private var completed: Set<String> = []
    private static let maxLineBytes = 1_048_576
    private static let terminalStatuses: Set<String> = [
        "completed", "failed", "cancelled", "canceled", "killed", "stopped"
    ]

    init(sessionId: String, path: String) {
        self.sessionId = sessionId
        self.path = path
    }

    func readCompletedTaskIDs() throws -> Set<String> {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let number = attributes[.systemFileNumber] as? NSNumber
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if number != fileNumber || size < offset {
            offset = 0
            partial.removeAll(keepingCapacity: true)
            skippingLongLine = false
            completed = []
            fileNumber = number
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        // Limit each sweep so a huge transcript cannot monopolize the reader queue.
        let end = min(size, offset + 8 * 1_048_576)
        while offset < end {
            guard let chunk = try file.read(upToCount: Int(min(65_536, end - offset))),
                  !chunk.isEmpty else { break }
            consume(chunk)
            offset += UInt64(chunk.count)
        }
        return completed
    }

    private func consume(_ chunk: Data) {
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 10) {
            append(chunk[start..<newline])
            if !skippingLongLine { readNotification(partial) }
            partial.removeAll(keepingCapacity: true)
            skippingLongLine = false
            start = newline + 1
        }
        append(chunk[start...])
    }

    private func append(_ bytes: Data) {
        guard !skippingLongLine else { return }
        guard partial.count + bytes.count <= Self.maxLineBytes else {
            partial.removeAll(keepingCapacity: true)
            skippingLongLine = true
            return
        }
        partial.append(bytes)
    }

    private func readNotification(_ line: Data) {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["type"] as? String == "queue-operation",
              record["operation"] as? String == "enqueue",
              record["sessionId"] as? String == sessionId,
              let content = record["content"] as? String else { return }
        let notification = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notification.hasPrefix("<task-notification>"),
              notification.hasSuffix("</task-notification>"),
              let id = field("task-id", in: notification), !id.isEmpty,
              let status = field("status", in: notification),
              Self.terminalStatuses.contains(status.lowercased()) else { return }
        completed.insert(id)
    }

    private func field(_ name: String, in content: String) -> String? {
        guard let start = content.range(of: "<\(name)>"),
              let end = content.range(of: "</\(name)>", range: start.upperBound..<content.endIndex)
        else { return nil }
        let value = content[start.upperBound..<end.lowerBound]
        guard !value.contains("<") else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
