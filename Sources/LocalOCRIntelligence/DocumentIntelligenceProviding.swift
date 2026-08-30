import LocalOCRModelCore

public struct ProvenancedIntelligenceResult<Value: Sendable>: Sendable {
    public let value: Value
    public let model: LocalModelProvenance

    public init(value: Value, model: LocalModelProvenance) {
        self.value = value
        self.model = model
    }
}

public protocol DocumentIntelligenceProviding: Sendable {
    var availability: IntelligenceAvailability { get async }

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary>
    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion>
    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]>
}
