public struct UnavailableIntelligenceProvider: DocumentIntelligenceProviding {
    public let availability: IntelligenceAvailability

    public init(_ availability: IntelligenceAvailability) {
        self.availability = availability
    }

    public func summarize(_ document: IntelligenceDocument) async throws -> IntelligenceSummary {
        throw IntelligenceError.unavailable(availability)
    }

    public func organize(_ document: IntelligenceDocument) async throws -> OrganizationSuggestion {
        throw IntelligenceError.unavailable(availability)
    }

    public func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> [ExtractedDocumentField] {
        throw IntelligenceError.unavailable(availability)
    }
}
