/// Tracks active inbound request identifiers and their cancellable work.
///
/// Entries remain reserved through terminal frame delivery. The fixed limit
/// bounds executing and output-blocked requests together.
actor RequestRegistry {
    enum Reservation: Equatable {
        case accepted
        case duplicate
        case overloaded
    }

    private enum Phase {
        case executing
        case sending
    }

    private struct Entry {
        var phase = Phase.executing
        var task: Task<Void, Never>?
        var cancelOnAttach = false
    }

    private var entries: [ID: Entry] = [:]
    private let limit: Int

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func reserve(_ id: ID) -> Reservation {
        guard entries[id] == nil else { return .duplicate }
        guard entries.count < limit else { return .overloaded }
        entries[id] = Entry()
        return .accepted
    }

    func attach(_ task: Task<Void, Never>, to id: ID) {
        guard var entry = entries[id] else {
            task.cancel()
            return
        }
        entry.task = task
        entries[id] = entry
        if entry.cancelOnAttach {
            task.cancel()
        }
    }

    /// Atomically transitions an executing request to its terminal send.
    func beginTerminal(_ id: ID) -> Bool {
        guard var entry = entries[id], entry.phase == .executing else { return false }
        entry.phase = .sending
        entries[id] = entry
        return true
    }

    /// Atomically assigns cancellation as the terminal path without releasing the ID.
    func beginCancellation(_ id: ID) -> Bool {
        guard var entry = entries[id], entry.phase == .executing else { return false }
        entry.phase = .sending
        entry.cancelOnAttach = true
        entries[id] = entry
        entry.task?.cancel()
        return true
    }

    /// Releases an ID only after its terminal frame has been delivered.
    func finishTerminal(_ id: ID) {
        guard entries[id]?.phase == .sending else { return }
        entries.removeValue(forKey: id)
    }

    func cancelAll() -> [Task<Void, Never>] {
        let tasks = entries.values.compactMap(\.task)
        entries.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        return tasks
    }
}
