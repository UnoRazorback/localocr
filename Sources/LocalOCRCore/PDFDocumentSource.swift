import CoreGraphics
import Foundation
import PDFKit

public protocol PDFDocumentReading: Sendable {
    func inspect(_ url: URL) throws -> PDFInspection
    func nativeText(in url: URL, pageIndex: Int) throws -> String
    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage
}

public struct PDFDocumentSource: PDFDocumentReading {
    public static let minimumNativeCharacters = 20

    public init() {}

    public func inspect(_ url: URL) throws -> PDFInspection {
        let document = try openDocument(at: url)
        var pageDetails: [PageInspection] = []

        for pageIndex in 0 ..< document.pageCount {
            let text = try nativeText(in: document, pageIndex: pageIndex)
            let characters = Self.nativeCharacterCount(in: text)
            pageDetails.append(
                PageInspection(
                    page: pageIndex + 1,
                    characters: characters,
                    searchable: characters >= Self.minimumNativeCharacters
                )
            )
        }

        let searchablePages = pageDetails.filter(\.searchable).map(\.page)
        let ocrNeededPages = pageDetails.filter { !$0.searchable }.map(\.page)
        return PDFInspection(
            pages: document.pageCount,
            searchablePages: searchablePages,
            ocrNeededPages: ocrNeededPages,
            characters: pageDetails.reduce(0) { $0 + $1.characters },
            fullySearchable: ocrNeededPages.isEmpty,
            pageDetails: pageDetails
        )
    }

    public func nativeText(in url: URL, pageIndex: Int) throws -> String {
        try nativeText(in: openDocument(at: url), pageIndex: pageIndex)
    }

    public func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage {
        let document = try openDocument(at: url)
        let page = try page(in: document, at: pageIndex)
        guard dpi > 0 else {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }

        let mediaBox = page.bounds(for: .mediaBox)
        let scale = CGFloat(dpi) / 72
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        guard [0, 90, 180, 270].contains(normalizedRotation) else {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }
        let displayTransform = page.transform(for: .mediaBox)
        let displayedSize = mediaBox
            .applying(displayTransform)
            .standardized
            .size
        let width = Int((displayedSize.width * scale).rounded(.up))
        let height = Int((displayedSize.height * scale).rounded(.up))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // PDFPage.draw applies the same display transform, including rotation
        // and MediaBox origin normalization.
        page.draw(with: .mediaBox, to: context)

        guard let image = context.makeImage() else {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }
        return image
    }

    static func nativeCharacterCount(in text: String) -> Int {
        text.unicodeScalars.count
    }

    private func openDocument(at url: URL) throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalOCRError.fileNotFound
        }
        guard let document = PDFDocument(url: url) else {
            throw LocalOCRError.unreadablePDF
        }
        return document
    }

    private func nativeText(in document: PDFDocument, pageIndex: Int) throws -> String {
        let page = try page(in: document, at: pageIndex)
        return (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func page(in document: PDFDocument, at pageIndex: Int) throws -> PDFPage {
        guard let page = document.page(at: pageIndex) else {
            throw LocalOCRError.pageOutOfBounds(page: pageIndex + 1, total: document.pageCount)
        }
        return page
    }
}
