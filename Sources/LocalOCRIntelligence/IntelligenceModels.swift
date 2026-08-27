import Foundation

public enum IntelligenceAvailability: String, Codable, Sendable, Equatable {
    case available
    case requiresMacOS26
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLanguage
}

public struct IntelligenceSourcePage: Codable, Sendable, Equatable {
    public let number: Int
    public let text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

public struct IntelligenceDocument: Codable, Sendable, Equatable {
    public let pages: [IntelligenceSourcePage]

    private enum CodingKeys: String, CodingKey {
        case pages
    }

    public init(pages: [IntelligenceSourcePage]) {
        self.pages = pages
            .compactMap { page in
                guard page.number >= 1 else { return nil }

                let trimmedText = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else { return nil }

                return IntelligenceSourcePage(number: page.number, text: trimmedText)
            }
            .sorted { $0.number < $1.number }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pages: try container.decode([IntelligenceSourcePage].self, forKey: .pages))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pages, forKey: .pages)
    }
}

public struct IntelligenceCitation: Codable, Sendable, Equatable {
    public let page: Int
    public let quote: String

    public init(page: Int, quote: String) {
        self.page = page
        self.quote = quote
    }
}

public struct IntelligenceSummary: Codable, Sendable, Equatable {
    public let text: String
    public let citations: [IntelligenceCitation]

    public init(text: String, citations: [IntelligenceCitation]) {
        self.text = text
        self.citations = citations
    }
}

public struct OrganizationSuggestion: Codable, Sendable, Equatable {
    public let title: String
    public let category: String
    public let tags: [String]
    public let citations: [IntelligenceCitation]

    public init(title: String, category: String, tags: [String], citations: [IntelligenceCitation]) {
        self.title = title
        self.category = category
        self.tags = tags
        self.citations = citations
    }
}

public struct ExtractedDocumentField: Codable, Sendable, Equatable {
    public let name: String
    public let value: String?
    public let sourcePage: Int?
    public let evidence: String?

    public init(name: String, value: String?, sourcePage: Int?, evidence: String?) {
        self.name = name
        self.value = value
        self.sourcePage = sourcePage
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
        case sourcePage
        case evidence
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encode(sourcePage, forKey: .sourcePage)
        try container.encode(evidence, forKey: .evidence)
    }
}
