import Foundation

public struct PageCountResponse: Sendable, Codable, Equatable {
    public let pages: Int

    public init(pages: Int) {
        self.pages = pages
    }
}

public struct PageInspectionResponse: Sendable, Codable, Equatable {
    public let page: Int
    public let characters: Int
    public let searchable: Bool

    public init(page: Int, characters: Int, searchable: Bool) {
        self.page = page
        self.characters = characters
        self.searchable = searchable
    }
}

public struct InspectPDFResponse: Sendable, Codable, Equatable {
    public let sourcePath: String
    public let sourceSHA256: String
    public let pages: Int
    public let searchablePages: Int
    public let ocrNeededPages: Int
    public let characters: Int
    public let fullySearchable: Bool
    public let pageDetails: [PageInspectionResponse]

    public init(
        sourcePath: String,
        sourceSHA256: String,
        pages: Int,
        searchablePages: Int,
        ocrNeededPages: Int,
        characters: Int,
        fullySearchable: Bool,
        pageDetails: [PageInspectionResponse]
    ) {
        self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.pages = pages
        self.searchablePages = searchablePages
        self.ocrNeededPages = ocrNeededPages
        self.characters = characters
        self.fullySearchable = fullySearchable
        self.pageDetails = pageDetails
    }
}

public enum OCRPageMethod: String, Sendable, Codable, Equatable {
    case existingText = "existing_text"
    case visionOCR = "vision_ocr"
}

public struct OCRLineResponse: Sendable, Codable, Equatable {
    public let text: String
    public let confidence: Float
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(text: String, confidence: Float, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRPageResponse: Sendable, Codable, Equatable {
    public let page: Int
    public let text: String
    public let method: OCRPageMethod
    public let lines: [OCRLineResponse]?

    public init(page: Int, text: String, method: OCRPageMethod, lines: [OCRLineResponse]?) {
        self.page = page
        self.text = text
        self.method = method
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey {
        case page
        case text
        case method
        case lines
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decode(Int.self, forKey: .page)
        text = try container.decode(String.self, forKey: .text)
        method = try container.decode(OCRPageMethod.self, forKey: .method)
        lines = try container.decodeIfPresent([OCRLineResponse].self, forKey: .lines)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(page, forKey: .page)
        try container.encode(text, forKey: .text)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(lines, forKey: .lines)
    }
}

public enum OCRPageOrientation: String, Sendable, Codable, Equatable {
    case up
    case upMirrored = "up_mirrored"
    case down
    case downMirrored = "down_mirrored"
    case left
    case leftMirrored = "left_mirrored"
    case right
    case rightMirrored = "right_mirrored"
}

public struct RotatedPageResponse: Sendable, Codable, Equatable {
    public let page: Int
    public let orientation: OCRPageOrientation

    public init(page: Int, orientation: OCRPageOrientation) {
        self.page = page
        self.orientation = orientation
    }
}

public struct PDFOCRResponse: Sendable, Codable, Equatable {
    public let sourcePath: String
    public let sourceSHA256: String
    public let pages: [OCRPageResponse]
    public let failedPages: [Int]
    public let emptyOCRPages: [Int]
    public let rotatedOCRPages: [RotatedPageResponse]

    public init(
        sourcePath: String,
        sourceSHA256: String,
        pages: [OCRPageResponse],
        failedPages: [Int],
        emptyOCRPages: [Int],
        rotatedOCRPages: [RotatedPageResponse]
    ) {
        self.sourcePath = sourcePath
        self.sourceSHA256 = sourceSHA256
        self.pages = pages
        self.failedPages = failedPages
        self.emptyOCRPages = emptyOCRPages
        self.rotatedOCRPages = rotatedOCRPages
    }
}

public enum BatchItemResponse: Sendable, Codable, Equatable {
    case success(PDFOCRResponse)
    case failure(sourcePath: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case status
        case sourcePath
        case sourceSHA256
        case pages
        case failedPages
        case emptyOCRPages
        case rotatedOCRPages
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "ok":
            self = .success(
                PDFOCRResponse(
                    sourcePath: try container.decode(String.self, forKey: .sourcePath),
                    sourceSHA256: try container.decode(String.self, forKey: .sourceSHA256),
                    pages: try container.decode([OCRPageResponse].self, forKey: .pages),
                    failedPages: try container.decode([Int].self, forKey: .failedPages),
                    emptyOCRPages: try container.decode([Int].self, forKey: .emptyOCRPages),
                    rotatedOCRPages: try container.decode([RotatedPageResponse].self, forKey: .rotatedOCRPages)
                )
            )
        case "error":
            self = .failure(
                sourcePath: try container.decode(String.self, forKey: .sourcePath),
                message: try container.decode(String.self, forKey: .error)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Unknown batch item status"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .success(response):
            try container.encode("ok", forKey: .status)
            try container.encode(response.sourcePath, forKey: .sourcePath)
            try container.encode(response.sourceSHA256, forKey: .sourceSHA256)
            try container.encode(response.pages, forKey: .pages)
            try container.encode(response.failedPages, forKey: .failedPages)
            try container.encode(response.emptyOCRPages, forKey: .emptyOCRPages)
            try container.encode(response.rotatedOCRPages, forKey: .rotatedOCRPages)
        case let .failure(sourcePath, message):
            try container.encode("error", forKey: .status)
            try container.encode(sourcePath, forKey: .sourcePath)
            try container.encode(message, forKey: .error)
        }
    }
}

public struct BatchOCRResponse: Sendable, Codable, Equatable {
    public let processed: Int
    public let succeeded: Int
    public let failed: Int
    public let results: [BatchItemResponse]

    public init(processed: Int, succeeded: Int, failed: Int, results: [BatchItemResponse]) {
        self.processed = processed
        self.succeeded = succeeded
        self.failed = failed
        self.results = results
    }
}

public struct ImageOCRResponse: Sendable, Codable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct SearchablePDFResponse: Sendable, Codable, Equatable {
    public let outputPath: String
    public let failedPages: [Int]

    public init(outputPath: String, failedPages: [Int]) {
        self.outputPath = outputPath
        self.failedPages = failedPages
    }
}
