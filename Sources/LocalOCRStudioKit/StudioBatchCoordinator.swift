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
    @ObservationIgnored private var preparationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var processingTaskID: UUID?

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
        cancelPreparationTasks()
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
        while !preparationTasks.isEmpty || processingTask != nil {
            let preparations = Array(preparationTasks.values)
            let processing = processingTask
            for task in preparations {
                await task.value
            }
            if let processing {
                await processing.value
            }
        }
    }

    private func beginPreparation() {
        generation = UUID()
        let preparationGeneration = generation
        cancelPreparationTasks()
        actionError = nil
        items = []

        let taskID = UUID()
        let selections = selectedURLs
        let requestedOutputRoot = selectedOutputRoot
        let enumerator = enumerator
        let planner = planner
        let task = Task { @MainActor [weak self] in
            let discovered = await enumerator.discover(selections: selections)
            guard let self else { return }
            guard !Task.isCancelled else {
                self.finishPreparationTask(taskID)
                return
            }
            guard self.accept(
                discovered,
                generation: preparationGeneration
            ) else {
                self.finishPreparationTask(taskID)
                return
            }
            guard !discovered.candidates.isEmpty,
                  let requestedOutputRoot
            else {
                self.finishPreparationTask(taskID)
                return
            }

            do {
                let plan = try await planner.makePlan(
                    discovery: discovered,
                    outputRoot: requestedOutputRoot
                )
                self.accept(plan, generation: preparationGeneration)
            } catch {
                self.acceptPreparationError(error, generation: preparationGeneration)
            }
            self.finishPreparationTask(taskID)
        }
        preparationTasks[taskID] = task
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

    private func cancelPreparationTasks() {
        for task in preparationTasks.values {
            task.cancel()
        }
    }

    private func finishPreparationTask(_ id: UUID) {
        preparationTasks.removeValue(forKey: id)
    }

    private func startProcessing(
        indices: [Int],
        refreshReservations: Bool
    ) {
        generation = UUID()
        let processingGeneration = generation
        cancelPreparationTasks()
        actionError = nil
        phase = .processing

        let taskID = UUID()
        processingTaskID = taskID
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process(
                indices: indices,
                refreshReservations: refreshReservations,
                generation: processingGeneration
            )
            self.finishProcessingTask(taskID)
        }
    }

    private func process(
        indices: [Int],
        refreshReservations: Bool,
        generation: UUID
    ) async {
        for index in indices {
            guard isCurrentProcessingGeneration(generation),
                  items.indices.contains(index),
                  items[index].state == .queued
            else {
                return
            }

            if refreshReservations {
                do {
                    guard let outputRoot else { return }
                    let refreshed = try await planner.refreshReservation(
                        for: items[index],
                        outputRoot: outputRoot
                    )
                    guard isCurrentProcessingGeneration(generation) else { return }
                    items[index].reservation = refreshed
                } catch {
                    guard isCurrentProcessingGeneration(generation) else { return }
                    if isCancellation(error) {
                        finishExecutorCancellation()
                        return
                    }
                    items[index].state = .failed(batchIssue(for: error))
                    continue
                }
            }

            let itemID = items[index].id
            items[index].state = .processing(.inspecting)
            let executionItem = items[index]

            do {
                let resultURL = try await executor.execute(executionItem) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.accept(
                            progress,
                            index: index,
                            itemID: itemID,
                            generation: generation
                        )
                    }
                }
                guard isCurrentProcessingGeneration(generation),
                      items.indices.contains(index),
                      items[index].id == itemID
                else {
                    return
                }
                items[index].state = .completed(resultURL)
            } catch {
                guard isCurrentProcessingGeneration(generation),
                      items.indices.contains(index),
                      items[index].id == itemID
                else {
                    return
                }
                if isCancellation(error) {
                    finishExecutorCancellation()
                    return
                }
                items[index].state = .failed(batchIssue(for: error))
            }
        }

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
