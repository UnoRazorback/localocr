import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
import Observation

@MainActor
public protocol StudioLocalModelManaging: AnyObject {
    var models: [StudioLocalModelRow] { get }
    var selection: LocalIntelligenceSelectionState { get }
    var isDetecting: Bool { get }
    var qualifyingIdentity: LocalModelIdentity? { get }
    var selectingIdentity: LocalModelIdentity? { get }
    var pendingExternalIdentity: LocalModelIdentity? { get }
    var externalConfirmation: StudioExternalModelConfirmation? { get }
    var error: StudioPresentedError? { get }

    func refreshSelection() async
    func detect() async
    func test(_ identity: LocalModelIdentity) async
    func selectApple() async
    func prepareExternalSelection(_ identity: LocalModelIdentity)
    func cancelExternalSelection()
    func confirmExternalSelection() async
    func reset() async
    func dismissError()
}

public struct StudioLocalModelRow: Identifiable, Sendable, Equatable {
    public let identity: LocalModelIdentity
    public let providerName: String
    public let modelName: String
    public let statusText: String
    public let localityReason: String
    public let locality: LocalModelLocality
    public let qualification: LocalModelQualificationStatus
    public let available: Bool
    public let selected: Bool
    public let qualifiedAt: Date?
    public let canTest: Bool
    public let canSelect: Bool

    public var id: LocalModelIdentity { identity }
}

public struct StudioExternalModelConfirmation: Sendable, Equatable {
    public static let approvedStatement = "LocalOCR will send OCR text to the selected third-party model harness over loopback on this Mac. The harness may keep its own logs or history. Review its privacy settings before continuing."

    public let identity: LocalModelIdentity
    public let providerName: String
    public let modelName: String
    public let statement: String
}

public struct StudioLocalModelManagerContract: Sendable, Equatable {
    public let title = "Manage Local Models"
    public let subtitle = "Choose what handles future summaries and extracted fields."
    public let discoveryExplanation = "Detection checks only local model details; it does not send document text."
    public let confirmationStatement = StudioExternalModelConfirmation.approvedStatement
    public let providerTitles = ["APPLE", "OLLAMA", "LM STUDIO"]
    public let allowedActions = [
        "Detect", "Test", "Recheck", "Select", "Reset selection", "Done",
        "Continue", "Cancel", "Retry", "Choose Another Local Model", "Use Apple System Model",
    ]
}

public struct StudioProcessingRoute: Sendable, Equatable {
    public let path: String
    public let modelDisclosure: String
    public let location: String

    public var accessibilityText: String {
        "Processing route: \(path). \(modelDisclosure). \(location)."
    }

    public init(provenance: LocalModelProvenance) {
        switch provenance.processing {
        case .onDevice:
            path = "LocalOCR → Apple system model"
            modelDisclosure = "Apple Foundation Models — system default"
            location = "On device"
        case .onDeviceLoopback:
            let provider = StudioSafeModelText.sanitize(provenance.providerDisplayName)
            let model = StudioSafeModelText.sanitize(provenance.model)
            path = "LocalOCR → loopback on this Mac → \(provider)"
            modelDisclosure = "\(provider) — \(model)"
            location = "On device via loopback"
        }
    }

    public init?(selection: LocalIntelligenceSelectionState) {
        switch selection {
        case .selected(.appleSystemDefault):
            self.init(provenance: .appleSystemDefault)
        case let .selected(.external(identity, qualification, _)):
            self.init(provenance: LocalModelProvenance(
                provider: identity.provider,
                providerDisplayName: Self.providerName(identity.provider),
                model: identity.model,
                processing: .onDeviceLoopback,
                fingerprint: identity.fingerprint,
                qualifiedAt: qualification.qualifiedAt
            ))
        case .none, .reset, .invalid:
            return nil
        }
    }

    private static func providerName(_ provider: LocalModelProviderID) -> String {
        switch provider {
        case .appleFoundationModels: "Apple Foundation Models"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }
}

enum StudioSafeModelText {
    static func sanitize(_ input: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(input.unicodeScalars.count)
        for scalar in input.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format:
                continue
            case .control, .lineSeparator, .paragraphSeparator, .surrogate,
                 .privateUse, .unassigned:
                scalars.append(Unicode.Scalar(32)!)
            default:
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

@MainActor
@Observable
public final class StudioLocalModelManagerViewModel: StudioLocalModelManaging {
    public private(set) var models: [StudioLocalModelRow] = []
    public private(set) var selection: LocalIntelligenceSelectionState = .none
    public private(set) var isDetecting = false
    public private(set) var qualifyingIdentity: LocalModelIdentity?
    public private(set) var selectingIdentity: LocalModelIdentity?
    public private(set) var pendingExternalIdentity: LocalModelIdentity?
    public private(set) var externalConfirmation: StudioExternalModelConfirmation?
    public private(set) var error: StudioPresentedError?

    @ObservationIgnored private let manager: any LocalIntelligenceManaging
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var qualificationDates: [LocalModelIdentity: Date] = [:]

    public init(
        manager: any LocalIntelligenceManaging,
        now: @escaping @Sendable () -> Date = Date.init,
        initialModels: [LocalModelDescriptor] = [],
        initialSelection: LocalIntelligenceSelectionState = .none
    ) {
        self.manager = manager
        self.now = now
        self.selection = initialSelection
        models = initialModels.map {
            Self.row(from: $0, qualificationDates: [:])
        }.sorted(by: Self.rowOrder)
    }

    public func refreshSelection() async {
        let operation = beginOperation()
        let state = await manager.status()
        let apple: LocalModelDescriptor? = if let appleManager = manager as? any LocalIntelligenceAppleDescribing {
            await appleManager.appleModel()
        } else {
            nil
        }
        guard generation == operation, !Task.isCancelled else { return }
        selection = state
        if let apple, !models.contains(where: { $0.identity == .appleSystemDefault }) {
            models.append(Self.row(from: apple, qualificationDates: qualificationDates))
            models.sort(by: Self.rowOrder)
        }
    }

    public func detect() async {
        let operation = beginOperation()
        isDetecting = true
        error = nil
        let descriptors = await manager.models()
        let state = await manager.status()
        guard generation == operation, !Task.isCancelled else { return }
        publish(descriptors, selection: state)
        isDetecting = false
    }

    public func test(_ identity: LocalModelIdentity) async {
        guard let row = models.first(where: { $0.identity == identity }), row.canTest else {
            error = Self.error(title: "Model Cannot Be Tested", message: "This model is not verified as local and available.")
            return
        }
        let operation = beginOperation()
        qualifyingIdentity = identity
        error = nil
        do {
            let outcome = try await manager.qualify(identity)
            if let date = outcome.receipt?.qualifiedAt { qualificationDates[identity] = date }
            let descriptors = await manager.models()
            let state = await manager.status()
            guard generation == operation, !Task.isCancelled else { return }
            publish(descriptors, selection: state)
            if outcome.status != .passed {
                error = Self.error(
                    title: "Model Test Failed",
                    message: "The model did not pass every Local Intelligence action."
                )
            }
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            self.error = Self.present(error)
        }
        if generation == operation { qualifyingIdentity = nil }
    }

    public func selectApple() async {
        let operation = beginOperation()
        selectingIdentity = .appleSystemDefault
        error = nil
        do {
            try await manager.selectApple()
            let state = await manager.status()
            let descriptors = await manager.models()
            guard generation == operation, !Task.isCancelled else { return }
            publish(descriptors, selection: state)
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            self.error = Self.present(error)
        }
        if generation == operation { selectingIdentity = nil }
    }

    public func prepareExternalSelection(_ identity: LocalModelIdentity) {
        guard identity.provider != .appleFoundationModels,
              let row = models.first(where: { $0.identity == identity }),
              row.canSelect
        else {
            error = Self.error(title: "Model Cannot Be Selected", message: "Test this exact local model before selecting it.")
            return
        }
        pendingExternalIdentity = identity
        externalConfirmation = StudioExternalModelConfirmation(
            identity: identity,
            providerName: Self.providerName(identity.provider),
            modelName: StudioSafeModelText.sanitize(identity.model),
            statement: StudioExternalModelConfirmation.approvedStatement
        )
        error = nil
    }

    public func cancelExternalSelection() {
        invalidateOperations()
        pendingExternalIdentity = nil
        externalConfirmation = nil
        selectingIdentity = nil
    }

    public func confirmExternalSelection() async {
        guard let identity = pendingExternalIdentity,
              externalConfirmation?.identity == identity
        else {
            error = Self.error(title: "Confirmation Required", message: "Review the exact harness and model before continuing.")
            return
        }
        let operation = beginOperation(clearPending: false)
        selectingIdentity = identity
        error = nil
        do {
            try await manager.selectExternal(identity, acknowledgmentAcceptedAt: now())
            let state = await manager.status()
            let descriptors = await manager.models()
            guard generation == operation, !Task.isCancelled else { return }
            pendingExternalIdentity = nil
            externalConfirmation = nil
            publish(descriptors, selection: state)
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            pendingExternalIdentity = nil
            externalConfirmation = nil
            selection = await manager.status()
            self.error = Self.present(error)
        }
        if generation == operation { selectingIdentity = nil }
    }

    public func reset() async {
        let operation = beginOperation()
        error = nil
        do {
            try await manager.reset()
            let state = await manager.status()
            let descriptors = await manager.models()
            guard generation == operation, !Task.isCancelled else { return }
            publish(descriptors, selection: state)
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            self.error = Self.present(error)
        }
    }

    public func dismissError() {
        error = nil
    }

    private func beginOperation(clearPending: Bool = true) -> UUID {
        invalidateOperations()
        if clearPending {
            pendingExternalIdentity = nil
            externalConfirmation = nil
        }
        let operation = generation
        return operation
    }

    private func invalidateOperations() {
        generation = UUID()
        isDetecting = false
        qualifyingIdentity = nil
        selectingIdentity = nil
    }

    private func publish(
        _ descriptors: [LocalModelDescriptor],
        selection: LocalIntelligenceSelectionState
    ) {
        self.selection = selection
        models = descriptors.map {
            Self.row(from: $0, qualificationDates: qualificationDates)
        }.sorted(by: Self.rowOrder)
    }

    private static func row(
        from descriptor: LocalModelDescriptor,
        qualificationDates: [LocalModelIdentity: Date]
    ) -> StudioLocalModelRow {
        let identity = descriptor.identity
        let isApple = identity.provider == .appleFoundationModels
        let availableAndLocal = descriptor.available && descriptor.locality == .verifiedLocal
        let canTest = !isApple && availableAndLocal
        let canSelect = availableAndLocal && (isApple || descriptor.qualification == .passed)
        let qualifiedAt = descriptor.qualifiedAt ?? qualificationDates[identity]
        return StudioLocalModelRow(
            identity: identity,
            providerName: providerName(identity.provider),
            modelName: isApple
                ? "Apple Foundation Models — system default"
                : StudioSafeModelText.sanitize(identity.model),
            statusText: statusText(descriptor),
            localityReason: StudioSafeModelText.sanitize(descriptor.localityReason),
            locality: descriptor.locality,
            qualification: descriptor.qualification,
            available: descriptor.available,
            selected: descriptor.selected,
            qualifiedAt: qualifiedAt,
            canTest: canTest,
            canSelect: canSelect
        )
    }

    private static func statusText(_ descriptor: LocalModelDescriptor) -> String {
        guard descriptor.available else { return "Unavailable" }
        switch descriptor.locality {
        case .blocked:
            return "Blocked: \(StudioSafeModelText.sanitize(descriptor.localityReason))"
        case .unverified:
            return "Unverified: \(StudioSafeModelText.sanitize(descriptor.localityReason))"
        case .verifiedLocal:
            switch descriptor.qualification {
            case .untested: return descriptor.identity.provider == .appleFoundationModels ? "Local" : "Needs testing · Local"
            case .passed: return descriptor.selected ? "Selected · Qualified · Local" : "Qualified · Local"
            case .failed: return "Test failed · Local"
            case .stale: return "Test expired · Recheck required"
            }
        }
    }

    private static func rowOrder(_ lhs: StudioLocalModelRow, _ rhs: StudioLocalModelRow) -> Bool {
        let order: [LocalModelProviderID: Int] = [
            .appleFoundationModels: 0, .ollama: 1, .lmStudio: 2,
        ]
        let lhsProvider = order[lhs.identity.provider] ?? 3
        let rhsProvider = order[rhs.identity.provider] ?? 3
        if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
        return lhs.identity.model.localizedStandardCompare(rhs.identity.model) == .orderedAscending
    }

    private static func providerName(_ provider: LocalModelProviderID) -> String {
        switch provider {
        case .appleFoundationModels: "Apple"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    private static func present(_ error: any Error) -> StudioPresentedError {
        guard let intelligence = error as? IntelligenceError else {
            return Self.error(title: "Local Model Action Failed", message: "The action could not finish. Try again.")
        }
        switch intelligence {
        case let .selection(.identityChanged(expected, _)):
            return Self.error(
                title: "Model Changed",
                message: "\(providerName(expected.provider)) now reports a different identity. Detect and test the model again."
            )
        case .selection(.providerUnavailable), .selection(.modelUnavailable):
            return Self.error(title: "Model Unavailable", message: "The selected local model is not available. Retry or choose another model.")
        case .selection(.localityBlocked), .selection(.localityUnverified):
            return Self.error(title: "Locality Not Verified", message: "LocalOCR cannot verify that this model runs only on this Mac.")
        case .selection(.qualificationRequired):
            return Self.error(title: "Model Test Required", message: "Test this exact model before selecting it.")
        case .selection(.acknowledgmentRequired):
            return Self.error(title: "Confirmation Required", message: "Review and confirm the exact harness and model again.")
        case .selection(.corruptReceipt):
            return Self.error(title: "Selection Unavailable", message: "Reset the selection, then choose a local model.")
        case .bridgeUnavailable:
            return Self.error(title: "Detection Unavailable", message: "Local model detection could not start. The existing selection was not changed.")
        case .bridgeInvalid, .malformedOutput, .ungroundedOutput:
            return Self.error(title: "Invalid Local Model Response", message: "LocalOCR discarded the response and did not change the selection.")
        case .generationTimedOut, .generationFailed, .contextOverflow:
            return Self.error(title: "Model Test Failed", message: "The synthetic model test could not finish safely.")
        case .unavailable:
            return Self.error(title: "Apple System Model Unavailable", message: "The Apple system model is not available on this Mac.")
        case .emptyDocument, .invalidFields, .cancelled:
            return Self.error(title: "Local Model Action Failed", message: "The action could not finish. Try again.")
        }
    }

    private static func error(title: String, message: String) -> StudioPresentedError {
        StudioPresentedError(title: title, message: message, details: nil)
    }
}

public actor StudioUnavailableLocalIntelligenceManager: LocalIntelligenceManaging {
    public init() {}

    public func models() async -> [LocalModelDescriptor] {
        [LocalModelDescriptor(
            identity: .appleSystemDefault,
            displayName: "Apple Foundation Models — system default",
            locality: .verifiedLocal,
            localityReason: "The Apple system model is unavailable.",
            qualification: .passed,
            available: false,
            selected: true
        )]
    }

    public func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome {
        throw IntelligenceError.unavailable(.requiresMacOS26)
    }

    public func selectApple() async throws {
        throw IntelligenceError.unavailable(.requiresMacOS26)
    }

    public func selectExternal(
        _ identity: LocalModelIdentity,
        acknowledgmentAcceptedAt: Date
    ) async throws {
        throw IntelligenceError.unavailable(.requiresMacOS26)
    }

    public func status() async -> LocalIntelligenceSelectionState {
        .selected(.appleSystemDefault)
    }

    public func reset() async throws {}
}
