public protocol LocalAIActivityReporting: Sendable {
    func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T
}

public actor LocalAIActivityReporter: LocalAIActivityReporting {
    private let ledger: any LocalAIActivityLedgerWriting
    private let clock: any LocalAIActivityClock
    let wakeHint: any LocalAIActivityWakeHintPosting

    public init(
        ledger: any LocalAIActivityLedgerWriting,
        clock: any LocalAIActivityClock,
        wakeHint: any LocalAIActivityWakeHintPosting = NoLocalAIActivityWakeHint()
    ) {
        self.ledger = ledger
        self.clock = clock
        self.wakeHint = wakeHint
    }

    public func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard let activityID = try? await ledger.begin(descriptor) else {
            return try await operation()
        }

        wakeHint.postRescanHint()
        let heartbeat = Task { [ledger, clock, wakeHint] in
            while !Task.isCancelled {
                try await clock.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                try? await ledger.heartbeat(activityID)
                wakeHint.postRescanHint()
            }
        }

        do {
            let value = try await operation()
            heartbeat.cancel()
            _ = await heartbeat.result
            try? await ledger.end(activityID, outcome: .success)
            wakeHint.postRescanHint()
            return value
        } catch {
            heartbeat.cancel()
            _ = await heartbeat.result
            try? await ledger.end(activityID, outcome: reportedOutcome(for: error))
            wakeHint.postRescanHint()
            throw error
        }
    }

    private func reportedOutcome(for error: any Error) -> LocalAIActivityOutcome {
        if error is CancellationError { return .cancelled }
        if let intelligenceError = error as? IntelligenceError,
           intelligenceError == .cancelled {
            return .cancelled
        }
        return .failure
    }
}

public struct DisabledLocalAIActivityReporter: LocalAIActivityReporting {
    public init() {}

    public func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await operation()
    }
}
