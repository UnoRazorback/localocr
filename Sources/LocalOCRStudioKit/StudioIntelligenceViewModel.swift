import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
import Observation

public enum StudioIntelligenceOperation: Sendable, Equatable {
    case summary
    case organization
    case fields
}

public enum StudioIntelligenceRecoveryAction: Sendable, Equatable {
    case retry
    case chooseAnotherLocalModel
    case useAppleSystemModel
}

public struct StudioIntelligenceRecovery: Sendable, Equatable {
    public let failedOperation: StudioIntelligenceOperation
    public let failure: LocalIntelligenceSelectionFailure
    public let message: String
    public let actions: [StudioIntelligenceRecoveryAction]
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
    public private(set) var summaryModel: LocalModelProvenance?
    public private(set) var organizationModel: LocalModelProvenance?
    public private(set) var fieldsModel: LocalModelProvenance?
    public private(set) var recovery: StudioIntelligenceRecovery?

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
        recovery = nil

        let provider = provider
        summaryTask = Task { [weak self] in
            do {
                let result = try await provider.summarize(context.document)
                try Task.checkCancellation()
                self?.finishSummary(
                    .result(result.value),
                    model: result.model,
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
            } catch let IntelligenceError.selection(failure) {
                self?.finishSummarySelectionFailure(
                    failure,
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
        recovery = nil

        let provider = provider
        organizationTask = Task { [weak self] in
            do {
                let result = try await provider.organize(context.document)
                try Task.checkCancellation()
                self?.finishOrganization(
                    .result(result.value),
                    model: result.model,
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
            } catch let IntelligenceError.selection(failure) {
                self?.finishOrganizationSelectionFailure(
                    failure,
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
        recovery = nil

        let provider = provider
        fieldsTask = Task { [weak self] in
            do {
                let result = try await provider.extract(
                    ["date", "total", "reference_number"],
                    from: context.document
                )
                try Task.checkCancellation()
                self?.finishFields(
                    .result(result.value),
                    model: result.model,
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
            } catch let IntelligenceError.selection(failure) {
                self?.finishFieldsSelectionFailure(
                    failure,
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

    public func retryRecovery() {
        guard let operation = recovery?.failedOperation else { return }
        switch operation {
        case .summary: summarize()
        case .organization: organize()
        case .fields: extractFields()
        }
    }

    public func clearRecovery() {
        recovery = nil
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
        model: LocalModelProvenance? = nil,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, summaryOperationID == operationID else { return }
        summaryTask = nil
        summaryState = state
        if let model { summaryModel = model }
        if case let .unavailable(reason) = state {
            setStateUnavailableIfNeeded(reason)
        }
    }

    private func finishOrganization(
        _ state: StudioIntelligenceState<OrganizationSuggestion>,
        model: LocalModelProvenance? = nil,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, organizationOperationID == operationID else { return }
        organizationTask = nil
        organizationState = state
        if let model { organizationModel = model }
        if case let .unavailable(reason) = state {
            setStateUnavailableIfNeeded(reason)
        }
    }

    private func finishFields(
        _ state: StudioIntelligenceState<[ExtractedDocumentField]>,
        model: LocalModelProvenance? = nil,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, fieldsOperationID == operationID else { return }
        fieldsTask = nil
        fieldsState = state
        if let model { fieldsModel = model }
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

    private func finishSummarySelectionFailure(
        _ failure: LocalIntelligenceSelectionFailure,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, summaryOperationID == operationID else { return }
        summaryTask = nil
        summaryState = .failure(Self.presentedSelectionFailure(failure))
        recovery = Self.recovery(for: .summary, failure: failure)
    }

    private func finishOrganizationSelectionFailure(
        _ failure: LocalIntelligenceSelectionFailure,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, organizationOperationID == operationID else { return }
        organizationTask = nil
        organizationState = .failure(Self.presentedSelectionFailure(failure))
        recovery = Self.recovery(for: .organization, failure: failure)
    }

    private func finishFieldsSelectionFailure(
        _ failure: LocalIntelligenceSelectionFailure,
        generation: UUID,
        operationID: UUID
    ) {
        guard self.generation == generation, fieldsOperationID == operationID else { return }
        fieldsTask = nil
        fieldsState = .failure(Self.presentedSelectionFailure(failure))
        recovery = Self.recovery(for: .fields, failure: failure)
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
        summaryModel = nil
        organizationModel = nil
        fieldsModel = nil
        recovery = nil
    }

    private static func recovery(
        for operation: StudioIntelligenceOperation,
        failure: LocalIntelligenceSelectionFailure
    ) -> StudioIntelligenceRecovery {
        StudioIntelligenceRecovery(
            failedOperation: operation,
            failure: failure,
            message: presentedSelectionFailure(failure).message,
            actions: [.retry, .chooseAnotherLocalModel, .useAppleSystemModel]
        )
    }

    private static func presentedSelectionFailure(
        _ failure: LocalIntelligenceSelectionFailure
    ) -> StudioPresentedError {
        let message: String = switch failure {
        case .corruptReceipt:
            "Choose a local model before using Local Intelligence."
        case .providerUnavailable, .modelUnavailable:
            "The selected local model is not available. Your OCR result is unchanged."
        case .localityUnverified, .localityBlocked:
            "LocalOCR can no longer verify that the selected model runs only on this Mac."
        case .qualificationRequired:
            "The selected model must pass the synthetic Local Intelligence test again."
        case .acknowledgmentRequired:
            "Review and confirm the selected model again before sending OCR text."
        case .identityChanged:
            "The selected model identity changed. Detect and test the exact model again."
        }
        return StudioPresentedError(
            title: "Local Model Needs Attention",
            message: message,
            details: nil
        )
    }

    private static let presentedFailure = StudioPresentedError(
        title: "Local Intelligence Failed",
        message: "Local Intelligence could not finish this request. Please try again.",
        details: nil
    )
}
