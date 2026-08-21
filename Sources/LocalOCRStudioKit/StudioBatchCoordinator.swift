import Foundation
import LocalOCRCore
import Observation

@MainActor
@Observable
public final class StudioBatchCoordinator {
    public private(set) var phase: StudioBatchPhase = .empty
    public private(set) var discovery: StudioBatchDiscovery?
    public private(set) var outputRoot: URL?
    public private(set) var items: [StudioBatchItem] = []
    public private(set) var actionError: StudioBatchIssue?

    public var canStart: Bool {
        phase == .reviewing && !items.isEmpty && outputRoot != nil
    }

    public var summary: StudioBatchSummary {
        StudioBatchSummary(
            items: items,
            skippedCount: discovery?.skipped.count ?? 0
        )
    }

    @ObservationIgnored private let enumerator: any StudioBatchInputEnumerating
    @ObservationIgnored private let planner: any StudioBatchOutputPlanning
    @ObservationIgnored private let executor: any StudioBatchItemExecuting
    @ObservationIgnored private var selectedURLs: [URL] = []
    @ObservationIgnored private var selectedOutputRoot: URL?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTaskID: UUID?
    @ObservationIgnored private var pendingPreparationRequest: StudioBatchPreparationRequest?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var processingTaskID: UUID?
    @ObservationIgnored private var progressTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeProgressRelay: StudioBatchProgressRelay?

    public init(
        enumerator: any StudioBatchInputEnumerating = BatchInputEnumerator(),
        planner: any StudioBatchOutputPlanning = BatchOutputPlanner(),
        executor: any StudioBatchItemExecuting = StudioBatchExecutor(
            client: LocalOCRStudioClient()
        )
    ) {
        self.enumerator = enumerator
        self.planner = planner
        self.executor = executor
    }

    public func addSelections(_ urls: [URL]) {
        guard phase == .empty || phase == .reviewing,
              !urls.isEmpty
        else {
            return
        }

        selectedURLs.append(contentsOf: urls)
        beginPreparation()
    }

    public func chooseOutputRoot(_ url: URL) {
        guard phase == .empty || phase == .reviewing else { return }

        selectedOutputRoot = url.standardizedFileURL
        outputRoot = selectedOutputRoot
        beginPreparation()
    }

    public func start() {
        guard canStart,
              processingTask == nil
        else {
            return
        }

        let queuedIndices = items.indices.filter { items[$0].state == .queued }
        guard !queuedIndices.isEmpty else {
            phase = .complete
            return
        }
        startProcessing(indices: queuedIndices, refreshReservations: false)
    }

    public func cancel() {
        guard phase == .processing else { return }

        generation = UUID()
        processingTask?.cancel()
        markPendingItemsCancelled()
        actionError = nil
        phase = .complete
    }

    public func retryFailed() {
        guard phase == .complete,
              processingTask == nil,
              outputRoot != nil
        else {
            return
        }

        let failedIndices = items.indices.filter { items[$0].state.isRetryable }
        guard !failedIndices.isEmpty else { return }

        for index in failedIndices {
            items[index].state = .queued
        }
        startProcessing(indices: failedIndices, refreshReservations: true)
    }

    public func startNewBatch() {
        generation = UUID()
        cancelPreparation()
        processingTask?.cancel()

        selectedURLs = []
        selectedOutputRoot = nil
        phase = .empty
        discovery = nil
        outputRoot = nil
        items = []
        actionError = nil
    }

    @_spi(Testing)
    public func waitUntilIdleForTesting() async {
        while preparationTask != nil || processingTask != nil || !progressTasks.isEmpty {
            let preparation = preparationTask
            let processing = processingTask
            let progressDeliveries = Array(progressTasks.values)
            if let preparation {
                await preparation.value
            }
            if let processing {
                await processing.value
            }
            for task in progressDeliveries {
                await task.value
            }
        }
    }

    @_spi(Testing)
    public func waitUntilPreparationIdleForTesting() async {
        while let preparationTask {
            await preparationTask.value
        }
    }

    @_spi(Testing)
    public func waitUntilProgressDeliveredForTesting() async {
        await activeProgressRelay?.waitUntilDeliveredThroughLatest()
    }

    @_spi(Testing)
    public var ownedPreparationTaskCountForTesting: Int {
        preparationTask == nil ? 0 : 1
    }

    @_spi(Testing)
    public var pendingPreparationRequestCountForTesting: Int {
        pendingPreparationRequest == nil ? 0 : 1
    }

    private func beginPreparation() {
        generation = UUID()
        actionError = nil
        items = []

        let request = StudioBatchPreparationRequest(
            generation: generation,
            selections: selectedURLs,
            requestedOutputRoot: selectedOutputRoot
        )
        guard let preparationTask else {
            startPreparation(request)
            return
        }

        pendingPreparationRequest = request
        preparationTask.cancel()
    }

    private func startPreparation(_ request: StudioBatchPreparationRequest) {
        let taskID = UUID()
        let enumerator = enumerator
        let planner = planner
        let task = Task { @MainActor [weak self] in
            defer { self?.finishPreparationTask(taskID) }
            let discovered = await enumerator.discover(selections: request.selections)
            guard !Task.isCancelled,
                  self?.accept(
                      discovered,
                      generation: request.generation
                  ) == true
            else { return }
            guard !discovered.candidates.isEmpty,
                  let requestedOutputRoot = request.requestedOutputRoot
            else { return }

            do {
                let plan = try await planner.makePlan(
                    discovery: discovered,
                    outputRoot: requestedOutputRoot
                )
                self?.accept(plan, generation: request.generation)
            } catch {
                self?.acceptPreparationError(error, generation: request.generation)
            }
        }
        preparationTaskID = taskID
        preparationTask = task
    }

    @discardableResult
    private func accept(
        _ discovered: StudioBatchDiscovery,
        generation: UUID
    ) -> Bool {
        guard self.generation == generation,
              phase == .empty || phase == .reviewing
        else {
            return false
        }

        discovery = discovered
        items = []
        actionError = nil
        phase = discovered.candidates.isEmpty ? .empty : .reviewing
        return true
    }

    private func accept(_ plan: StudioBatchPlan, generation: UUID) {
        guard self.generation == generation,
              phase == .reviewing
        else {
            return
        }

        outputRoot = plan.outputRoot
        items = plan.items
        actionError = nil
    }

    private func acceptPreparationError(_ error: any Error, generation: UUID) {
        guard self.generation == generation,
              phase == .reviewing
        else {
            return
        }

        items = []
        actionError = batchIssue(for: error)
    }

    private func cancelPreparation() {
        pendingPreparationRequest = nil
        preparationTask?.cancel()
    }

    private func finishPreparationTask(_ id: UUID) {
        guard preparationTaskID == id else { return }

        preparationTask = nil
        preparationTaskID = nil
        guard let pendingPreparationRequest else { return }

        self.pendingPreparationRequest = nil
        startPreparation(pendingPreparationRequest)
    }

    private func startProcessing(
        indices: [Int],
        refreshReservations: Bool
    ) {
        generation = UUID()
        let processingGeneration = generation
        cancelPreparation()
        actionError = nil
        phase = .processing

        let taskID = UUID()
        let planner = planner
        let executor = executor
        processingTaskID = taskID
        processingTask = Task { @MainActor [weak self] in
            defer { self?.finishProcessingTask(taskID) }
            for index in indices {
                guard var item = self?.queuedItem(
                    at: index,
                    generation: processingGeneration
                ) else { return }

                let itemID = item.id
                if refreshReservations {
                    do {
                        guard let outputRoot = self?.outputRoot else { return }
                        let refreshed = try await planner.refreshReservation(
                            for: item,
                            outputRoot: outputRoot
                        )
                        guard let refreshedItem = self?.accept(
                            refreshed,
                            index: index,
                            itemID: itemID,
                            generation: processingGeneration
                        ) else { return }
                        item = refreshedItem
                    } catch {
                        guard let disposition = self?.acceptProcessingError(
                            error,
                            index: index,
                            itemID: itemID,
                            generation: processingGeneration
                        ) else { return }
                        if disposition == .stop { return }
                        continue
                    }
                }

                guard let executionItem = self?.beginExecution(
                    item,
                    index: index,
                    generation: processingGeneration
                ), let delivery = self?.beginProgressDelivery(
                    index: index,
                    itemID: itemID,
                    generation: processingGeneration
                ) else { return }

                do {
                    let resultURL = try await executor.execute(executionItem) { progress in
                        delivery.relay.submit(progress)
                    }
                    delivery.relay.finish()
                    await delivery.task.value
                    guard self?.accept(
                        resultURL,
                        index: index,
                        itemID: itemID,
                        generation: processingGeneration
                    ) == true else { return }
                } catch {
                    delivery.relay.finish()
                    await delivery.task.value
                    guard let disposition = self?.acceptProcessingError(
                        error,
                        index: index,
                        itemID: itemID,
                        generation: processingGeneration
                    ) else { return }
                    if disposition == .stop { return }
                }
            }

            self?.completeProcessing(generation: processingGeneration)
        }
    }

    private func queuedItem(at index: Int, generation: UUID) -> StudioBatchItem? {
        guard isCurrentProcessingGeneration(generation),
              items.indices.contains(index),
              items[index].state == .queued
        else {
            return nil
        }
        return items[index]
    }

    private func accept(
        _ reservation: StudioBatchReservation,
        index: Int,
        itemID: UUID,
        generation: UUID
    ) -> StudioBatchItem? {
        guard isCurrentProcessingGeneration(generation),
              items.indices.contains(index),
              items[index].id == itemID,
              items[index].state == .queued
        else {
            return nil
        }
        items[index].reservation = reservation
        return items[index]
    }

    private func beginExecution(
        _ item: StudioBatchItem,
        index: Int,
        generation: UUID
    ) -> StudioBatchItem? {
        guard isCurrentProcessingGeneration(generation),
              items.indices.contains(index),
              items[index].id == item.id,
              items[index].state == .queued
        else {
            return nil
        }
        items[index].state = .processing(.inspecting)
        return items[index]
    }

    private func beginProgressDelivery(
        index: Int,
        itemID: UUID,
        generation: UUID
    ) -> StudioBatchProgressDelivery? {
        guard isCurrentProcessingGeneration(generation) else { return nil }

        let relay = StudioBatchProgressRelay()
        let taskID = UUID()
        let task = Task { @MainActor [weak self, relay] in
            for await event in relay.events {
                self?.accept(
                    event.progress,
                    index: index,
                    itemID: itemID,
                    generation: generation
                )
                relay.markDelivered(event.sequence)
            }
            self?.finishProgressTask(taskID, relay: relay)
        }
        progressTasks[taskID] = task
        activeProgressRelay = relay
        return StudioBatchProgressDelivery(relay: relay, task: task)
    }

    private func accept(
        _ resultURL: URL,
        index: Int,
        itemID: UUID,
        generation: UUID
    ) -> Bool {
        guard isCurrentProcessingGeneration(generation),
              items.indices.contains(index),
              items[index].id == itemID,
              case .processing = items[index].state
        else {
            return false
        }
        items[index].state = .completed(resultURL)
        return true
    }

    private func acceptProcessingError(
        _ error: any Error,
        index: Int,
        itemID: UUID,
        generation: UUID
    ) -> StudioBatchProcessingDisposition? {
        guard isCurrentProcessingGeneration(generation),
              items.indices.contains(index),
              items[index].id == itemID
        else {
            return nil
        }
        if isCancellation(error) {
            finishExecutorCancellation()
            return .stop
        }
        items[index].state = .failed(batchIssue(for: error))
        return .continueBatch
    }

    private func completeProcessing(generation: UUID) {
        guard isCurrentProcessingGeneration(generation) else { return }
        phase = .complete
    }

    private func accept(
        _ progress: StudioProgress,
        index: Int,
        itemID: UUID,
        generation: UUID
    ) {
        guard isCurrentProcessingGeneration(generation),
              items.indices.contains(index),
              items[index].id == itemID,
              case .processing = items[index].state
        else {
            return
        }
        items[index].state = .processing(progress)
    }

    private func isCurrentProcessingGeneration(_ generation: UUID) -> Bool {
        self.generation == generation && phase == .processing
    }

    private func finishExecutorCancellation() {
        generation = UUID()
        markPendingItemsCancelled()
        actionError = nil
        phase = .complete
    }

    private func markPendingItemsCancelled() {
        for index in items.indices {
            switch items[index].state {
            case .queued, .processing:
                items[index].state = .cancelled
            case .completed, .skipped, .failed, .cancelled:
                break
            }
        }
    }

    private func finishProcessingTask(_ id: UUID) {
        guard processingTaskID == id else { return }
        processingTask = nil
        processingTaskID = nil
    }

    private func finishProgressTask(
        _ id: UUID,
        relay: StudioBatchProgressRelay
    ) {
        progressTasks.removeValue(forKey: id)
        if activeProgressRelay === relay {
            activeProgressRelay = nil
        }
    }
}

private enum StudioBatchProcessingDisposition {
    case continueBatch
    case stop
}

private struct StudioBatchPreparationRequest {
    let generation: UUID
    let selections: [URL]
    let requestedOutputRoot: URL?
}

private struct StudioBatchProgressDelivery {
    let relay: StudioBatchProgressRelay
    let task: Task<Void, Never>
}

private final class StudioBatchProgressRelay: @unchecked Sendable {
    struct Event: Sendable {
        let sequence: Int
        let progress: StudioProgress
    }

    let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var nextSequence = 0
    private var latestSubmittedSequence = -1
    private var latestDeliveredSequence = -1
    private var deliveryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var isFinished = false

    init() {
        let stream = AsyncStream.makeStream(of: Event.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func submit(_ progress: StudioProgress) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let sequence = nextSequence
        nextSequence += 1
        latestSubmittedSequence = sequence
        continuation.yield(Event(sequence: sequence, progress: progress))
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        continuation.finish()
        lock.unlock()
    }

    func markDelivered(_ sequence: Int) {
        lock.lock()
        latestDeliveredSequence = max(latestDeliveredSequence, sequence)
        let ready = deliveryWaiters.filter { latestDeliveredSequence >= $0.0 }
        deliveryWaiters.removeAll { latestDeliveredSequence >= $0.0 }
        lock.unlock()
        ready.forEach { $0.1.resume() }
    }

    func waitUntilDeliveredThroughLatest() async {
        let target = latestSubmitted()
        guard target >= 0 else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if latestDeliveredSequence >= target {
                lock.unlock()
                continuation.resume()
            } else {
                deliveryWaiters.append((target, continuation))
                lock.unlock()
            }
        }
    }

    private func latestSubmitted() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return latestSubmittedSequence
    }
}

private func batchIssue(for error: any Error) -> StudioBatchIssue {
    let presented = StudioErrorPresentation.present(error)
    return StudioBatchIssue(
        title: presented.title,
        message: presented.message,
        details: presented.details
    )
}

private func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError {
        return true
    }
    return (error as? LocalOCRError) == .cancelled
}
