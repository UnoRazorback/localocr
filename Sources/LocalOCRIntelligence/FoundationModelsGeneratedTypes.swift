struct FoundationModelsGeneratedFact: Sendable, Equatable {
    let value: String
    let page: Int
    let evidence: String
}

struct FoundationModelsGeneratedSummaryItem: Sendable, Equatable {
    let text: String
    let page: Int
    let evidence: String
}

struct FoundationModelsGeneratedSummary: Sendable, Equatable {
    let items: [FoundationModelsGeneratedSummaryItem]
}

struct FoundationModelsGeneratedOrganization: Sendable, Equatable {
    let title: FoundationModelsGeneratedFact?
    let category: FoundationModelsGeneratedFact?
    let tags: [FoundationModelsGeneratedFact]
}

struct FoundationModelsGeneratedField: Sendable, Equatable {
    let name: String
    let value: String?
    let page: Int?
    let evidence: String?
}

struct FoundationModelsGeneratedExtraction: Sendable, Equatable {
    let fields: [FoundationModelsGeneratedField]
}

protocol FoundationModelsSessionDriving: Sendable {
    func summarize(prompt: String) async throws -> FoundationModelsGeneratedSummary
    func organize(prompt: String) async throws -> FoundationModelsGeneratedOrganization
    func extract(names: [String], prompt: String) async throws -> FoundationModelsGeneratedExtraction
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable(description: "A source-grounded factual statement from OCR text")
struct FoundationModelsLiveSummaryItem {
    @Guide(description: "A concise factual statement supported by the evidence")
    var text: String

    @Guide(description: "The one-based source page number", .minimum(1))
    var page: Int

    @Guide(description: "An exact quote from that source page")
    var evidence: String
}

@available(macOS 26.0, *)
@Generable(description: "A source-grounded summary of one OCR text chunk")
struct FoundationModelsLiveSummary {
    @Guide(description: "Grounded factual statements", .maximumCount(12))
    var items: [FoundationModelsLiveSummaryItem]
}

@available(macOS 26.0, *)
@Generable(description: "A suggested value with exact source evidence")
struct FoundationModelsLiveFact {
    @Guide(description: "The suggested value")
    var value: String

    @Guide(description: "The one-based source page number", .minimum(1))
    var page: Int

    @Guide(description: "An exact quote from that source page")
    var evidence: String
}

@available(macOS 26.0, *)
@Generable(description: "Source-grounded organization suggestions for one OCR text chunk")
struct FoundationModelsLiveOrganization {
    @Guide(description: "A grounded concise document title, or nil when unsupported")
    var title: FoundationModelsLiveFact?

    @Guide(description: "A grounded document category, or nil when unsupported")
    var category: FoundationModelsLiveFact?

    @Guide(description: "Grounded document tags", .maximumCount(5))
    var tags: [FoundationModelsLiveFact]
}

@available(macOS 26.0, *)
@Generable(description: "One requested field extracted from OCR text")
struct FoundationModelsLiveExtractedField {
    @Guide(description: "The requested field name exactly as provided")
    var name: String

    @Guide(description: "The exact extracted value, or nil when absent")
    var value: String?

    @Guide(description: "The one-based source page, or nil when absent")
    var page: Int?

    @Guide(description: "An exact quote supporting the value, or nil when absent")
    var evidence: String?
}

@available(macOS 26.0, *)
@Generable(description: "Requested fields extracted from one OCR text chunk")
struct FoundationModelsLiveExtraction {
    @Guide(description: "Extracted requested fields", .maximumCount(32))
    var fields: [FoundationModelsLiveExtractedField]
}
#endif
