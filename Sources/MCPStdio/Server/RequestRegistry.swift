/// Tracks active inbound request identifiers and their cancellable work.
///
/// Reservation and task attachment are separate so the server can reject a
/// duplicate before it starts any handler work.
actor RequestRegistry {
    private struct Entry {
        var task: Task<Void, Never>?
    }

    private var entries: [ID: Entry] = [:]

    func reserve(_ id: ID) -> Bool {
        guard entries[id] == nil else { return false }
        entries[id] = Entry()
        return true
    }

    func attach(_ task: Task<Void, Never>, to id: ID) {
        guard var entry = entries[id] else {
            task.cancel()
            return
        }
        entry.task = task
        entries[id] = entry
    }

    /// Atomically claims cancellation as this request's terminal path.
    func cancel(_ id: ID) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.task?.cancel()
        return true
    }

    /// Removes an active request. Only the first terminal path returns true.
    func complete(_ id: ID) -> Bool {
        entries.removeValue(forKey: id) != nil
    }

    func cancelAll() -> [Task<Void, Never>] {
        let tasks = entries.values.compactMap(\.task)
        entries.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        return tasks
    }
}
