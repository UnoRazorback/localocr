public protocol DocumentIntelligenceProviding: Sendable {
    var availability: IntelligenceAvailability { get async }

    func summarize(_ document: IntelligenceDocument) async throws -> IntelligenceSummary
    func organize(_ document: IntelligenceDocument) async throws -> OrganizationSuggestion
    func extract(_ names: [String], from document: IntelligenceDocument) async throws -> [ExtractedDocumentField]
}
