/// Tracks active inbound request identifiers and their cancellable work.
///
/// Entries remain reserved through terminal frame delivery. Protocol
/// reservations and live handler tasks have independent fixed bounds.
actor RequestRegistry {
    struct Lease: Hashable, Sendable {
        fileprivate let generation: UInt64
    }

    enum Reservation: Equatable {
        case accepted(Lease)
        case duplicate
        case overloaded
    }

    private enum Phase {
        case executing
        case sending
    }

    private struct Entry {
        let lease: Lease
        var phase = Phase.executing
    }

    private struct LiveHandler {
        var task: Task<Void, Never>?
        var cancellationRequested = false
    }

    private var entries: [ID: Entry] = [:]
    private var liveHandlers: [Lease: LiveHandler] = [:]
    private var nextGeneration: UInt64 = 1
    private let limit: Int

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func reserve(_ id: ID) -> Reservation {
        guard entries[id] == nil else { return .duplicate }
        guard entries.count < limit else { return .overloaded }
        guard nextGeneration < UInt64.max else { return .overloaded }
        let lease = Lease(generation: nextGeneration)
        nextGeneration += 1
        entries[id] = Entry(lease: lease)
        return .accepted(lease)
    }

    func claimHandler(id: ID, lease: Lease) -> Bool {
        guard let entry = entries[id], entry.lease == lease, entry.phase == .executing else {
            return false
        }
        guard liveHandlers.count < limit else { return false }
        liveHandlers[lease] = LiveHandler()
        return true
    }

    func attachHandler(_ task: Task<Void, Never>, to lease: Lease) {
        guard var handler = liveHandlers[lease] else {
            task.cancel()
            return
        }
        handler.task = task
        liveHandlers[lease] = handler
        if handler.cancellationRequested {
            task.cancel()
        }
    }

    func handlerDidExit(_ lease: Lease) {
        liveHandlers.removeValue(forKey: lease)
    }

    /// Atomically transitions an executing request to its terminal send.
    func beginTerminal(id: ID, lease: Lease) -> Bool {
        guard var entry = entries[id], entry.lease == lease, entry.phase == .executing else {
            return false
        }
        entry.phase = .sending
        entries[id] = entry
        return true
    }

    /// Atomically assigns cancellation as the terminal path without releasing the ID.
    func beginCancellation(_ id: ID) -> Lease? {
        guard var entry = entries[id], entry.phase == .executing else { return nil }
        entry.phase = .sending
        entries[id] = entry
        if var handler = liveHandlers[entry.lease] {
            handler.cancellationRequested = true
            liveHandlers[entry.lease] = handler
            handler.task?.cancel()
        }
        return entry.lease
    }

    /// Releases an ID only after its terminal frame has been delivered.
    func finishTerminal(id: ID, lease: Lease) {
        guard let entry = entries[id], entry.lease == lease, entry.phase == .sending else { return }
        entries.removeValue(forKey: id)
    }

    func cancelAll() -> [Task<Void, Never>] {
        let tasks = liveHandlers.values.compactMap(\.task)
        entries.removeAll(keepingCapacity: false)
        liveHandlers.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        return tasks
    }
}
