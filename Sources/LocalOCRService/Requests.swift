import Foundation
import LocalOCRCore

public enum LocalOCRRequestError: Error, Sendable, Equatable {
    case invalidDPI(Int)
    case emptyBatch
}

public struct PDFOCRRequest: Sendable, Equatable {
    public let fileURL: URL
    public let pageRange: String?
    public let dpi: Int
    public let forceOCR: Bool
    public let includeLines: Bool
    public let usesCache: Bool

    public init(
        fileURL: URL,
        pageRange: String? = nil,
        dpi: Int = 250,
        forceOCR: Bool = false,
        includeLines: Bool = false,
        usesCache: Bool = true
    ) throws {
        try Self.validate(dpi: dpi)
        self.fileURL = fileURL
        self.pageRange = pageRange
        self.dpi = dpi
        self.forceOCR = forceOCR
        self.includeLines = includeLines
        self.usesCache = usesCache
    }

    public func pageIndexes(totalPages: Int) throws -> [Int] {
        try PageRange.parse(pageRange, totalPages: totalPages)
    }

    static func validate(dpi: Int) throws {
        guard (72 ... 600).contains(dpi) else {
            throw LocalOCRRequestError.invalidDPI(dpi)
        }
    }
}

public struct BatchOCRRequest: Sendable, Equatable {
    public let fileURLs: [URL]
    public let pageRange: String?
    public let dpi: Int
    public let forceOCR: Bool
    public let includeLines: Bool
    public let usesCache: Bool

    public init(
        fileURLs: [URL],
        pageRange: String? = nil,
        dpi: Int = 250,
        forceOCR: Bool = false,
        includeLines: Bool = false,
        usesCache: Bool = true
    ) throws {
        guard !fileURLs.isEmpty else {
            throw LocalOCRRequestError.emptyBatch
        }
        try PDFOCRRequest.validate(dpi: dpi)
        self.fileURLs = fileURLs
        self.pageRange = pageRange
        self.dpi = dpi
        self.forceOCR = forceOCR
        self.includeLines = includeLines
        self.usesCache = usesCache
    }

    public func pageIndexes(totalPages: Int) throws -> [Int] {
        try PageRange.parse(pageRange, totalPages: totalPages)
    }
}

public struct ImageOCRRequest: Sendable, Equatable {
    public let fileURL: URL
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool

    public init(
        fileURL: URL,
        recognitionLanguages: [String] = [],
        usesLanguageCorrection: Bool = true
    ) {
        self.fileURL = fileURL
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
    }
}

public struct SearchablePDFRequest: Sendable, Equatable {
    public let fileURL: URL
    public let outputURL: URL?
    public let dpi: Int
    public let forceOCR: Bool
    public let usesCache: Bool

    public init(
        fileURL: URL,
        outputURL: URL? = nil,
        dpi: Int = 250,
        forceOCR: Bool = false,
        usesCache: Bool = true
    ) throws {
        try PDFOCRRequest.validate(dpi: dpi)
        self.fileURL = fileURL
        self.outputURL = outputURL
        self.dpi = dpi
        self.forceOCR = forceOCR
        self.usesCache = usesCache
    }

    public func pageIndexes(totalPages: Int) throws -> [Int] {
        try PageRange.parse(nil, totalPages: totalPages)
    }
}
