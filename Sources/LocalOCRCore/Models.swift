import Foundation
import ImageIO

public struct RecognitionSettings: Sendable, Codable, Hashable {
    public var dpi: Int = 250
    public var forceOCR: Bool = false
    public var recognitionLanguages: [String] = []
    public var usesLanguageCorrection: Bool = true

    public init(
        dpi: Int = 250,
        forceOCR: Bool = false,
        recognitionLanguages: [String] = [],
        usesLanguageCorrection: Bool = true
    ) {
        self.dpi = dpi
        self.forceOCR = forceOCR
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
    }
}

public struct OCRRequest: Sendable, Equatable {
    public let sourceURL: URL
    public let pageSelection: String?
    public let settings: RecognitionSettings

    public init(sourceURL: URL, pageSelection: String?, settings: RecognitionSettings) {
        self.sourceURL = sourceURL
        self.pageSelection = pageSelection
        self.settings = settings
    }
}

public struct PageInspection: Sendable, Codable, Equatable {
    public let page: Int
    public let characters: Int
    public let searchable: Bool

    public init(page: Int, characters: Int, searchable: Bool) {
        self.page = page
        self.characters = characters
        self.searchable = searchable
    }
}

public struct PDFInspection: Sendable, Codable, Equatable {
    public let pages: Int
    public let searchablePages: [Int]
    public let ocrNeededPages: [Int]
    public let characters: Int
    public let fullySearchable: Bool
    public let pageDetails: [PageInspection]

    public init(
        pages: Int,
        searchablePages: [Int],
        ocrNeededPages: [Int],
        characters: Int,
        fullySearchable: Bool,
        pageDetails: [PageInspection]
    ) {
        self.pages = pages
        self.searchablePages = searchablePages
        self.ocrNeededPages = ocrNeededPages
        self.characters = characters
        self.fullySearchable = fullySearchable
        self.pageDetails = pageDetails
    }

    private enum CodingKeys: String, CodingKey {
        case pages
        case searchablePages = "searchable_pages"
        case ocrNeededPages = "ocr_needed_pages"
        case characters
        case fullySearchable = "fully_searchable"
        case pageDetails = "page_details"
    }
}

public enum PageMethod: String, Sendable, Codable, Equatable {
    case existingText = "existing_text"
    case visionOCR = "vision_ocr"
}

public struct TextLine: Sendable, Codable, Equatable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case boundingBox = "bounding_box"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Float.self, forKey: .confidence)
        boundingBox = try CGRectContractValue(from: container, forKey: .boundingBox).rect
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(CGRectContractValue(boundingBox), forKey: .boundingBox)
    }
}

public struct PageResult: Sendable, Codable, Equatable {
    public let page: Int
    public let text: String
    public let method: PageMethod
    public let lines: [TextLine]
    public let orientation: CGImagePropertyOrientation

    public init(
        page: Int,
        text: String,
        method: PageMethod,
        lines: [TextLine],
        orientation: CGImagePropertyOrientation
    ) {
        self.page = page
        self.text = text
        self.method = method
        self.lines = lines
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey {
        case page
        case text
        case method
        case lines
        case orientation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decode(Int.self, forKey: .page)
        text = try container.decode(String.self, forKey: .text)
        method = try container.decode(PageMethod.self, forKey: .method)
        lines = try container.decode([TextLine].self, forKey: .lines)
        let rawOrientation = try container.decode(UInt32.self, forKey: .orientation)
        guard let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) else {
            throw DecodingError.dataCorruptedError(forKey: .orientation, in: container, debugDescription: "Unknown image orientation")
        }
        self.orientation = orientation
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(page, forKey: .page)
        try container.encode(text, forKey: .text)
        try container.encode(method, forKey: .method)
        try container.encode(lines, forKey: .lines)
        try container.encode(orientation.rawValue, forKey: .orientation)
    }
}

public struct OCRResult: Sendable, Codable, Equatable {
    public let sourceSHA256: String
    public let pages: [PageResult]
    public let failedPages: [Int]
    public let emptyOCRPages: [Int]
    public let rotatedOCRPages: [Int: CGImagePropertyOrientation]

    public init(
        sourceSHA256: String,
        pages: [PageResult],
        failedPages: [Int],
        emptyOCRPages: [Int],
        rotatedOCRPages: [Int: CGImagePropertyOrientation]
    ) {
        self.sourceSHA256 = sourceSHA256
        self.pages = pages
        self.failedPages = failedPages
        self.emptyOCRPages = emptyOCRPages
        self.rotatedOCRPages = rotatedOCRPages
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSHA256 = "source_sha256"
        case pages
        case failedPages = "failed_pages"
        case emptyOCRPages = "empty_ocr_pages"
        case rotatedOCRPages = "rotated_ocr_pages"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        pages = try container.decode([PageResult].self, forKey: .pages)
        failedPages = try container.decode([Int].self, forKey: .failedPages)
        emptyOCRPages = try container.decode([Int].self, forKey: .emptyOCRPages)
        let rawOrientations = try container.decode([String: UInt32].self, forKey: .rotatedOCRPages)
        var orientations: [Int: CGImagePropertyOrientation] = [:]
        for (page, rawOrientation) in rawOrientations {
            guard let pageNumber = Int(page), let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) else {
                throw DecodingError.dataCorruptedError(forKey: .rotatedOCRPages, in: container, debugDescription: "Invalid rotated page orientation")
            }
            orientations[pageNumber] = orientation
        }
        rotatedOCRPages = orientations
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceSHA256, forKey: .sourceSHA256)
        try container.encode(pages, forKey: .pages)
        try container.encode(failedPages, forKey: .failedPages)
        try container.encode(emptyOCRPages, forKey: .emptyOCRPages)
        let rawOrientations = Dictionary(uniqueKeysWithValues: rotatedOCRPages.map { (String($0.key), $0.value.rawValue) })
        try container.encode(rawOrientations, forKey: .rotatedOCRPages)
    }
}

public enum OCRProgress: Sendable, Equatable {
    case inspecting
    case recognizing(page: Int, total: Int)
    case assembling
    case completed
}

private struct CGRectContractValue: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    init<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws {
        self = try container.decode(Self.self, forKey: key)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
