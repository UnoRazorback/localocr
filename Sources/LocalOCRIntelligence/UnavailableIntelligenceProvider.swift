public struct UnavailableIntelligenceProvider: DocumentIntelligenceProviding {
    public let availability: IntelligenceAvailability

    public init(_ availability: IntelligenceAvailability) {
        self.availability = availability
    }

    public func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        throw IntelligenceError.unavailable(availability)
    }

    public func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        throw IntelligenceError.unavailable(availability)
    }

    public func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        throw IntelligenceError.unavailable(availability)
    }
}
