import Foundation
import LocalOCRModelCore

/// Shared CLI/MCP wire contract. Optional attestation fields are explicit JSON nulls.
public struct LocalModelResponse: Encodable, Sendable {
    public let provenance: LocalModelProvenance
    public init(_ provenance: LocalModelProvenance) { self.provenance = provenance }
    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id", providerDisplayName = "provider_display_name"
        case model, processing, fingerprint
        case harnessVersion = "harness_version", qualifiedAt = "qualified_at"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provenance.provider.rawValue, forKey: .providerID)
        try c.encode(provenance.providerDisplayName, forKey: .providerDisplayName)
        try c.encode(provenance.model, forKey: .model)
        try c.encode(provenance.processing.rawValue, forKey: .processing)
        try c.encode(provenance.fingerprint, forKey: .fingerprint)
        try c.encode(provenance.harnessVersion, forKey: .harnessVersion)
        try c.encode(provenance.qualifiedAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: .qualifiedAt)
    }
}

public struct SummarizeDocumentResponse: Encodable, Sendable {
    public let text: String
    public let citations: [IntelligenceCitation]
    public let localModel: LocalModelResponse
    public init(_ result: ProvenancedIntelligenceResult<IntelligenceSummary>) {
        text = result.value.text
        citations = result.value.citations
        localModel = LocalModelResponse(result.model)
    }
    private enum CodingKeys: String, CodingKey { case text, citations; case localModel = "local_model" }
}

public struct OrganizeDocumentResponse: Encodable, Sendable {
    public let title: String
    public let category: String
    public let tags: [String]
    public let citations: [IntelligenceCitation]
    public let localModel: LocalModelResponse
    public init(_ result: ProvenancedIntelligenceResult<OrganizationSuggestion>) {
        title = result.value.title
        category = result.value.category
        tags = result.value.tags
        citations = result.value.citations
        localModel = LocalModelResponse(result.model)
    }
    private enum CodingKeys: String, CodingKey { case title, category, tags, citations; case localModel = "local_model" }
}

public struct ExtractDocumentFieldsResponse: Encodable, Sendable {
    public let fields: [ExtractedDocumentField]
    public let localModel: LocalModelResponse
    public init(_ result: ProvenancedIntelligenceResult<[ExtractedDocumentField]>) {
        fields = result.value
        localModel = LocalModelResponse(result.model)
    }
    private enum CodingKeys: String, CodingKey { case fields; case localModel = "local_model" }
}
