import Foundation
import LocalOCRIntelligence
import Observation

public enum StudioIntelligenceOperation: Sendable, Equatable {
    case summary
    case organization
    case fields
}

public enum StudioIntelligenceState<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case running
    case result(Value)
    case failure(StudioPresentedError)
    case unavailable(IntelligenceAvailability)
}

@MainActor
@Observable
public final class StudioIntelligenceViewModel {
    public private(set) var availability: IntelligenceAvailability
    public private(set) var summaryState: StudioIntelligenceState<IntelligenceSummary> = .idle
    public private(set) var organizationState: StudioIntelligenceState<OrganizationSuggestion> = .idle
    public private(set) var fieldsState: StudioIntelligenceState<[ExtractedDocumentField]> = .idle

    @ObservationIgnored private let provider: any DocumentIntelligenceProviding
    @ObservationIgnored private var document: IntelligenceDocument?
    @ObservationIgnored private var documentIdentity: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var summaryOperationID = UUID()
    @ObservationIgnored private var organizationOperationID = UUID()
    @ObservationIgnored private var fieldsOperationID = UUID()
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var organizationTask: Task<Void, Never>?
    @ObservationIgnored private var fieldsTask: Task<Void, Never>?

    public init(
        provider: any DocumentIntelligenceProviding,
        availability: IntelligenceAvailability
    ) {
        self.provider = provider
        self.availability = availability
    }

    public func refreshAvailability() async {
        setAvailability(await provider.availability)
    }

    public func setAvailability(_ availability: IntelligenceAvailability) {
        guard self.availability != availability else { return }
        self.availability = availability

        guard availability != .available else {
            resetStates()
            return
        }

        cancelTasksAndInvalidateOperations()
        if document != nil {
            setAllStatesUnavailable(availability)
        }
    }

    public func setDocument(_ document: IntelligenceDocument, identity: String) {
        guard documentIdentity != identity else { return }
        cancelTasksAndInvalidateOperations()
        generation = UUID()
        self.document = document
        documentIdentity = identity
        resetStates()
    }

    public func summarize() {
        guard let context = operationContext(for: .summary) else { return }
        summaryTask?.cancel()
        let operationID = UUID()
        summaryOperationID = operationID
        summaryState = .running

        let provider = provider
        summaryTask = Task { [weak self] in
            do {
                let result = try await provider.summarize(context.document)
                try Task.checkCancellation()
                self?.finishSummary(
                    .result(result),
                    generation: context.generation,
                    operationID: operationID
                )
            } catch is CancellationError {
                self?.finishSummaryCancellation(
                    generation: context.generation,
                    operationID: operationID
                )
            } catch let error as IntelligenceError where error == .cancelled {
                self?.finishSummaryCancellation(
                    generation: context.generation,
                    operationID: operationID
                )
            } catch let IntelligenceError.unavailable(reason) {
                self?.finishSummary(
                    .unavailable(reason),
                    generation: context.generation,
                    operationID: operationID
                )
            } catch {
                self?.finishSummary(
                    .failure(Self.presentedFailure),
                    generation: context.generation,
                    operationID: operationID
                )
            }
        }
    }

    public func organize() {
        guard let context = operationContext(for: .organization) else { return }
        organizationTask?.cancel()
        let operationID = UUID()
        organizationOperationID = operationID
        organizationState = .running

        let provider = provider
        organizationTask = Task { [weak self] in
            do {
                let result = try await provider.organize(context.document)
                try Task.checkCancellation()
                self?.finishOrganization(
                    .result(result),
                    generation: context.generation,
                    operationID: operationID
                )
            } catch is CancellationError {
                self?.finishOrganizationCancellation(
                    generation: context.generation,
                    operationID: operationID
                )
            } catch let error as IntelligenceError where error == .cancelled {
                self?.finishOrganizationCancellation(
                    generation: context.generation,
                    operationID: operationID
                )
            } catch let IntelligenceError.unavailable(reason) {
                self?.finishOrganization(
                    .unavailable(reason),
                    generation: context.generation,
                    operationID: operationID
                )
            } catch {
                self?.finishOrganization(
                    .failure(Self.presentedFailure),
                    generation: context.generation,
                    operationID: operationID
                )
            }
        }
    }

    public func extractFields() {
        guard let context = operationContext(for: .fields) else { return }
        fieldsTask?.cancel()
        let operationID = UUID()
        fieldsOperationID = operationID
        fieldsState = .running

        let provider = provider
        fieldsTask = Task { [weak self] in
            do {
                let result = try await provider.extract(
                    ["date", "total", "reference_number"],
                    from: context.document
                )
                try Task.checkCancellation()
                self?.finishFields(
                    .result(result),
                    generation: context.generation,
                    operationID: operationID
                )
            } catch is CancellationError {
                self?.finishFieldsCancellation(
                    generation: context.generation,
                    operationID: operationID
                )
            } catch let error as IntelligenceError where error == .cancelled {
                self?.finishFieldsCancellation(
                    generation: context.generation,
                    operationID: operationID
                )
            } catch let IntelligenceError.unavailable(reason) {
                self?.finishFields(
                    .unavailable(reason),
                    generation: context.generation,
                    operationID: operationID
                )
            } catch {
                self?.finishFields(
                    .failure(Self.presentedFailure),
                    generation: context.generation,
                    operationID: operationID
                )
            }
        }
    }

    public func cancel(_ operation: StudioIntelligenceOperation) {
        switch operation {
        case .summary:
            summaryTask?.cancel()
            summaryTask = nil
            summaryOperationID = UUID()
            summaryState = .idle
        case .organization:
            organizationTask?.cancel()
            organizationTask = nil
            organizationOperationID = UUID()
            organizationState = .idle
        case .fields:
            fieldsTask?.cancel()
            fieldsTask = nil
            fieldsOperationID = UUID()
            fieldsState = .idle
        }
    }

    public func clearForProcessAnotherDocument() {
        clear()
    }

    public func clearForWorkspaceSwitch() {
        clear()
    }

    public func clearForWindowTeardown() {
        clear()
    }

    private struct OperationContext {
        let document: IntelligenceDocument
        let generation: UUID
    }

    private func operationContext(for operation: StudioIntelligenceOperation) -> OperationContext? {
        guard let document else { return nil }
        guard availability == .available else {
            switch operation {
            case .summary:
                summaryState = .unavailable(availability)
            case .organization:
                organizationState = .unavailable(availability)
            case .fields:
                fieldsState = .unavailable(availability)
            }
            return nil
        }
        return OperationContext(document: document, generation: generation)
    }

    private func setStateUnavailableIfNeeded(_ reason: IntelligenceAvailability) {
        availability = reason
        cancelTasksAndInvalidateOperations()
        setAllStatesUnavailable(reason)
    }

    private func setAllStatesUnavailable(_ reason: IntelligenceAvailability) {
        summaryState = .unavailable(reason)
        organizationState = .unavailable(reason)
        fieldsState = .unavailable(reason)
    }

    private func finishSummary(
        _ state: StudioIntelligenceState<IntelligenceSummary>,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, summaryOperationID == operationID else { return }
        summaryTask = nil
        summaryState = state
        if case let .unavailable(reason) = state {
            setStateUnavailableIfNeeded(reason)
        }
    }

    private func finishOrganization(
        _ state: StudioIntelligenceState<OrganizationSuggestion>,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, organizationOperationID == operationID else { return }
        organizationTask = nil
        organizationState = state
        if case let .unavailable(reason) = state {
            setStateUnavailableIfNeeded(reason)
        }
    }

    private func finishFields(
        _ state: StudioIntelligenceState<[ExtractedDocumentField]>,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, fieldsOperationID == operationID else { return }
        fieldsTask = nil
        fieldsState = state
        if case let .unavailable(reason) = state {
            setStateUnavailableIfNeeded(reason)
        }
    }

    private func finishSummaryCancellation(generation: UUID, operationID: UUID) {
        finishSummary(.idle, generation: generation, operationID: operationID)
    }

    private func finishOrganizationCancellation(generation: UUID, operationID: UUID) {
        finishOrganization(.idle, generation: generation, operationID: operationID)
    }

    private func finishFieldsCancellation(generation: UUID, operationID: UUID) {
        finishFields(.idle, generation: generation, operationID: operationID)
    }

    private func clear() {
        cancelTasksAndInvalidateOperations()
        generation = UUID()
        document = nil
        documentIdentity = nil
        resetStates()
    }

    private func cancelTasksAndInvalidateOperations() {
        summaryTask?.cancel()
        organizationTask?.cancel()
        fieldsTask?.cancel()
        summaryTask = nil
        organizationTask = nil
        fieldsTask = nil
        summaryOperationID = UUID()
        organizationOperationID = UUID()
        fieldsOperationID = UUID()
    }

    private func resetStates() {
        summaryState = .idle
        organizationState = .idle
        fieldsState = .idle
    }

    private static let presentedFailure = StudioPresentedError(
        title: "Local Intelligence Failed",
        message: "Local Intelligence could not finish this request. Please try again.",
        details: nil
    )
}
