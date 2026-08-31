import Foundation
import LocalOCRIntelligence

public enum StudioDocumentKind: Sendable, Equatable {
    case pdf
    case image
}

public enum StudioProgress: Sendable, Equatable {
    case inspecting
    case recognizing(page: Int, total: Int)
    case assembling
}

public struct StudioDocumentResult: Sendable, Equatable {
    public let sourceURL: URL
    public let sourceSHA256: String
    public let kind: StudioDocumentKind
    public let pageCount: Int
    public let searchablePages: Int
    public let ocrNeededPages: Int
    public let text: String
    public let failedPages: [Int]
    public let intelligenceDocument: IntelligenceDocument

    public init(
        sourceURL: URL,
        sourceSHA256: String,
        kind: StudioDocumentKind,
        pageCount: Int,
        searchablePages: Int,
        ocrNeededPages: Int,
        text: String,
        failedPages: [Int],
        intelligenceDocument: IntelligenceDocument? = nil
    ) {
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
        self.kind = kind
        self.pageCount = pageCount
        self.searchablePages = searchablePages
        self.ocrNeededPages = ocrNeededPages
        self.text = text
        self.failedPages = failedPages
        self.intelligenceDocument = intelligenceDocument ?? IntelligenceDocument(
            pages: [IntelligenceSourcePage(number: 1, text: text)]
        )
    }
}

public enum StudioClientError: Error, Sendable, Equatable {
    case sourceChanged
}
