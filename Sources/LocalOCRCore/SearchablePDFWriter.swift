import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import PDFKit

public struct SearchablePDFResult: Sendable, Equatable {
    public let outputURL: URL
    public let failedPages: [Int]
    public let isComplete: Bool

    public init(outputURL: URL, failedPages: [Int], isComplete: Bool) {
        self.outputURL = outputURL
        self.failedPages = failedPages
        self.isComplete = isComplete
    }
}

public protocol SearchablePDFWriting: Sendable {
    func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult
}

public struct SearchablePDFWriter: SearchablePDFWriting {
    private let pdfReader: any PDFDocumentReading

    public init(pdfReader: any PDFDocumentReading = PDFDocumentSource()) {
        self.pdfReader = pdfReader
    }

    public func write(
        sourceURL: URL,
        destinationURL: URL,
        pageResults: [PageResult]
    ) async throws -> SearchablePDFResult {
        do {
            let fileManager = FileManager.default
            try validateDestination(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                fileManager: fileManager
            )

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw LocalOCRError.fileNotFound
            }
            guard let sourceDocument = PDFDocument(url: sourceURL) else {
                throw LocalOCRError.unreadablePDF
            }

            let resultsByPage = try indexedResults(
                pageResults,
                pageCount: sourceDocument.pageCount
            )
            let failedPages = (1...sourceDocument.pageCount).filter {
                resultsByPage[$0] == nil
            }
            let temporaryURL =
                destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".localocr-\(UUID().uuidString).pdf")
            defer {
                try? fileManager.removeItem(at: temporaryURL)
            }

            try Task.checkCancellation()
            try writeTemporaryPDF(
                sourceDocument: sourceDocument,
                destinationURL: temporaryURL,
                resultsByPage: resultsByPage
            )
            try Task.checkCancellation()
            try validateTemporaryPDF(
                at: temporaryURL,
                pageCount: sourceDocument.pageCount,
                resultsByPage: resultsByPage
            )
            try Task.checkCancellation()
            try atomicReplace(temporaryURL: temporaryURL, destinationURL: destinationURL)

            return SearchablePDFResult(
                outputURL: destinationURL,
                failedPages: failedPages,
                isComplete: failedPages.isEmpty
            )
        } catch is CancellationError {
            throw LocalOCRError.cancelled
        }
    }

    private func validateDestination(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard sourceURL.isFileURL, destinationURL.isFileURL,
            sourceURL.resolvingSymlinksInPath().standardizedFileURL
                != destinationURL.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw LocalOCRError.invalidDestination
        }

        let parent = destinationURL.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard
            fileManager.fileExists(
                atPath: parent.path,
                isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue
        else {
            throw LocalOCRError.invalidDestination
        }

        var destinationIsDirectory = ObjCBool(false)
        if fileManager.fileExists(
            atPath: destinationURL.path,
            isDirectory: &destinationIsDirectory
        ), destinationIsDirectory.boolValue {
            throw LocalOCRError.invalidDestination
        }
    }

    private func indexedResults(
        _ pageResults: [PageResult],
        pageCount: Int
    ) throws -> [Int: PageResult] {
        var indexed: [Int: PageResult] = [:]
        for result in pageResults {
            guard (1...pageCount).contains(result.page),
                indexed.updateValue(result, forKey: result.page) == nil
            else {
                throw LocalOCRError.outputValidationFailed
            }
        }
        return indexed
    }

    private func writeTemporaryPDF(
        sourceDocument: PDFDocument,
        destinationURL: URL,
        resultsByPage: [Int: PageResult]
    ) throws {
        let drawingURL =
            destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".localocr-drawing-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: drawingURL)
        }

        guard let consumer = CGDataConsumer(url: drawingURL as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw LocalOCRError.invalidDestination
        }

        for pageIndex in 0..<sourceDocument.pageCount {
            try Task.checkCancellation()
            guard let page = sourceDocument.page(at: pageIndex) else {
                throw LocalOCRError.outputValidationFailed
            }
            let mediaBox = page.bounds(for: .mediaBox)
            context.beginPDFPage(pageInfo(for: page))

            context.saveGState()
            let rotation = page.rotation
            page.rotation = 0
            context.translateBy(x: mediaBox.minX, y: mediaBox.minY)
            page.draw(with: .mediaBox, to: context)
            page.rotation = rotation
            context.restoreGState()

            if let result = resultsByPage[pageIndex + 1],
                result.method == .visionOCR
            {
                context.saveGState()
                context.concatenate(
                    page.transform(for: .mediaBox).inverted()
                )
                drawInvisibleText(
                    result.lines,
                    orientation: result.orientation,
                    mediaBox: CGRect(origin: .zero, size: mediaBox.size),
                    in: context
                )
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()

        guard let outputDocument = PDFDocument(url: drawingURL),
            outputDocument.pageCount == sourceDocument.pageCount
        else {
            throw LocalOCRError.outputValidationFailed
        }
        for pageIndex in 0..<sourceDocument.pageCount {
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                let outputPage = outputDocument.page(at: pageIndex)
            else {
                throw LocalOCRError.outputValidationFailed
            }
            outputPage.rotation = sourcePage.rotation
        }
        guard outputDocument.write(to: destinationURL) else {
            throw LocalOCRError.outputValidationFailed
        }
    }

    private func pageInfo(for page: PDFPage) -> CFDictionary {
        [
            kCGPDFContextMediaBox as String: rectangleData(
                page.bounds(for: .mediaBox)
            ),
            kCGPDFContextCropBox as String: rectangleData(
                page.bounds(for: .cropBox)
            ),
            kCGPDFContextBleedBox as String: rectangleData(
                page.bounds(for: .bleedBox)
            ),
            kCGPDFContextTrimBox as String: rectangleData(
                page.bounds(for: .trimBox)
            ),
            kCGPDFContextArtBox as String: rectangleData(
                page.bounds(for: .artBox)
            ),
        ] as CFDictionary
    }

    private func rectangleData(_ rectangle: CGRect) -> CFData {
        var rectangle = rectangle
        return withUnsafeBytes(of: &rectangle) {
            Data($0) as CFData
        }
    }

    private func drawInvisibleText(
        _ lines: [TextLine],
        orientation: CGImagePropertyOrientation,
        mediaBox: CGRect,
        in context: CGContext
    ) {
        for recognizedLine in lines {
            let text = recognizedLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let normalizedBox = originalImageBox(
                for: recognizedLine.boundingBox.standardized,
                orientation: orientation
            )
            let pageBox = CGRect(
                x: mediaBox.minX + normalizedBox.minX * mediaBox.width,
                y: mediaBox.minY + normalizedBox.minY * mediaBox.height,
                width: normalizedBox.width * mediaBox.width,
                height: normalizedBox.height * mediaBox.height
            )
            guard pageBox.width > 0, pageBox.height > 0 else {
                continue
            }
            let textBoxSize = orientedTextBoxSize(
                for: pageBox,
                orientation: orientation
            )

            let unitFont = CTFontCreateWithName("Helvetica" as CFString, 1, nil)
            let unitLine = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): unitFont
                    ]
                )
            )
            var unitAscent: CGFloat = 0
            var unitDescent: CGFloat = 0
            var unitLeading: CGFloat = 0
            let unitWidth = CGFloat(
                CTLineGetTypographicBounds(
                    unitLine,
                    &unitAscent,
                    &unitDescent,
                    &unitLeading
                )
            )
            let unitHeight = unitAscent + unitDescent
            guard unitWidth > 0, unitHeight > 0 else {
                continue
            }

            let fontSize = min(
                textBoxSize.width / unitWidth,
                textBoxSize.height / unitHeight
            )
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font
                    ]
                )
            )
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baseline =
                (textBoxSize.height - ascent - descent) / 2
                + descent

            context.saveGState()
            orientTextContext(
                context,
                in: pageBox,
                orientation: orientation
            )
            context.setTextDrawingMode(.invisible)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    private func orientedTextBoxSize(
        for pageBox: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .right, .left:
            CGSize(width: pageBox.height, height: pageBox.width)
        default:
            pageBox.size
        }
    }

    private func orientTextContext(
        _ context: CGContext,
        in pageBox: CGRect,
        orientation: CGImagePropertyOrientation
    ) {
        switch orientation {
        case .right:
            context.translateBy(x: pageBox.maxX, y: pageBox.minY)
            context.rotate(by: .pi / 2)
        case .down:
            context.translateBy(x: pageBox.maxX, y: pageBox.maxY)
            context.rotate(by: .pi)
        case .left:
            context.translateBy(x: pageBox.minX, y: pageBox.maxY)
            context.rotate(by: -.pi / 2)
        default:
            context.translateBy(x: pageBox.minX, y: pageBox.minY)
        }
    }

    private func originalImageBox(
        for orientedBox: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> CGRect {
        switch orientation {
        case .right:
            CGRect(
                x: 1 - orientedBox.maxY,
                y: orientedBox.minX,
                width: orientedBox.height,
                height: orientedBox.width
            )
        case .down:
            CGRect(
                x: 1 - orientedBox.maxX,
                y: 1 - orientedBox.maxY,
                width: orientedBox.width,
                height: orientedBox.height
            )
        case .left:
            CGRect(
                x: orientedBox.minY,
                y: 1 - orientedBox.maxX,
                width: orientedBox.height,
                height: orientedBox.width
            )
        default:
            orientedBox
        }
    }

    private func validateTemporaryPDF(
        at temporaryURL: URL,
        pageCount: Int,
        resultsByPage: [Int: PageResult]
    ) throws {
        let inspection: PDFInspection
        do {
            inspection = try pdfReader.inspect(temporaryURL)
        } catch {
            throw LocalOCRError.outputValidationFailed
        }
        guard inspection.pages == pageCount else {
            throw LocalOCRError.outputValidationFailed
        }

        for result in resultsByPage.values where result.method == .visionOCR {
            let outputText: String
            do {
                outputText = try pdfReader.nativeText(
                    in: temporaryURL,
                    pageIndex: result.page - 1
                )
            } catch {
                throw LocalOCRError.outputValidationFailed
            }
            let expectedLines = result.lines
                .map { normalizedText($0.text) }
                .filter { !$0.isEmpty }
            let expectedText = normalizedText(result.text)
            let expectedFragments =
                expectedLines.isEmpty
                ? [expectedText].filter { !$0.isEmpty }
                : expectedLines
            let normalizedOutput = normalizedText(outputText)
            guard !expectedFragments.isEmpty,
                expectedFragments.allSatisfy({ normalizedOutput.contains($0) })
            else {
                throw LocalOCRError.outputValidationFailed
            }
        }
    }

    private func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func atomicReplace(
        temporaryURL: URL,
        destinationURL: URL
    ) throws {
        let result: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let temporaryPath, let destinationPath else {
                    return Int32(-1)
                }
                return Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard result == 0 else {
            throw LocalOCRError.invalidDestination
        }
    }
}
