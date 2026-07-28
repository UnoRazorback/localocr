import CoreGraphics
import Foundation
import ImageIO
import LocalOCRCore
import PDFKit
import Testing

@Suite struct SearchablePDFWriterTests {
    @Test func preservesPagesPixelsNativeTextAndSourceWhileAddingInvisibleOCR() async throws {
        let sourceURL = try #require(
            Bundle.module.url(
                forResource: "overlay-source",
                withExtension: "pdf",
                subdirectory: "Fixtures"
            )
        )
        let sourceBytes = try Data(contentsOf: sourceURL)
        let location = try temporaryPDFLocation()
        let outputURL = location.outputURL
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }

        let result = try await SearchablePDFWriter().write(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            pageResults: [
                PageResult(
                    page: 1,
                    text: "Synthetic native text has more than twenty characters.",
                    method: .existingText,
                    lines: [
                        TextLine(
                            text: "DUPLICATE NATIVE OVERLAY",
                            confidence: 1,
                            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1)
                        )
                    ],
                    orientation: .up
                ),
                PageResult(
                    page: 2,
                    text: "LOCAL OCR OVERLAY",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "LOCAL OCR OVERLAY",
                            confidence: 0.99,
                            boundingBox: CGRect(x: 0.16, y: 0.18, width: 0.68, height: 0.08)
                        )
                    ],
                    orientation: .up
                ),
                PageResult(
                    page: 3,
                    text: "LANDSCAPE OCR OVERLAY",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "LANDSCAPE OCR OVERLAY",
                            confidence: 0.98,
                            boundingBox: CGRect(x: 0.08, y: 0.72, width: 0.84, height: 0.12)
                        )
                    ],
                    orientation: .right
                ),
                PageResult(
                    page: 4,
                    text: "ROTATED OCR OVERLAY",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "ROTATED OCR OVERLAY",
                            confidence: 0.97,
                            boundingBox: CGRect(x: 0.12, y: 0.14, width: 0.7, height: 0.1)
                        )
                    ],
                    orientation: .up
                ),
            ]
        )

        #expect(
            result
                == SearchablePDFResult(
                    outputURL: outputURL,
                    failedPages: [],
                    isComplete: true
                )
        )
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let source = try #require(PDFDocument(url: sourceURL))
        let output = try #require(PDFDocument(url: outputURL))
        #expect(output.pageCount == source.pageCount)

        for pageIndex in 0..<source.pageCount {
            let sourcePage = try #require(source.page(at: pageIndex))
            let outputPage = try #require(output.page(at: pageIndex))
            #expect(outputPage.bounds(for: .mediaBox) == sourcePage.bounds(for: .mediaBox))
            #expect(outputPage.rotation == sourcePage.rotation)
            try expectSampledPixelsMatch(source: sourcePage, output: outputPage)
        }

        let nativeText = try #require(output.page(at: 0)?.string)
        #expect(
            nativeText.components(
                separatedBy: "Synthetic native text has more than twenty characters."
            )
            .count - 1 == 1)
        #expect(!nativeText.contains("DUPLICATE NATIVE OVERLAY"))
        #expect(try #require(output.page(at: 1)?.string).contains("LOCAL OCR OVERLAY"))
        let landscapePage = try #require(output.page(at: 2))
        let landscapeSelection = try #require(
            output.findString("LANDSCAPE OCR OVERLAY", withOptions: []).first
        )
        let landscapeBounds = landscapeSelection.bounds(for: landscapePage)
        #expect(landscapeBounds.minX >= 70)
        #expect(landscapeBounds.minY < 200)
        #expect(landscapeBounds.height > landscapeBounds.width * 5)
    }

    @Test func reportsEveryMissingPageAsIncompleteWhilePreservingItsAppearance() async throws {
        let sourceURL = try fixtureURL()
        let location = try temporaryPDFLocation()
        let outputURL = location.outputURL
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }

        let result = try await SearchablePDFWriter().write(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            pageResults: [
                PageResult(
                    page: 1,
                    text: "Synthetic native text has more than twenty characters.",
                    method: .existingText,
                    lines: [],
                    orientation: .up
                ),
                PageResult(
                    page: 3,
                    text: "LANDSCAPE OCR OVERLAY",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "LANDSCAPE OCR OVERLAY",
                            confidence: 0.98,
                            boundingBox: CGRect(x: 0.08, y: 0.72, width: 0.84, height: 0.12)
                        )
                    ],
                    orientation: .right
                ),
                PageResult(
                    page: 4,
                    text: "ROTATED OCR OVERLAY",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "ROTATED OCR OVERLAY",
                            confidence: 0.97,
                            boundingBox: CGRect(x: 0.12, y: 0.14, width: 0.7, height: 0.1)
                        )
                    ],
                    orientation: .up
                ),
            ]
        )

        #expect(result.failedPages == [2])
        #expect(result.isComplete == false)
        let source = try #require(PDFDocument(url: sourceURL))
        let output = try #require(PDFDocument(url: outputURL))
        #expect(output.pageCount == 4)
        try expectSampledPixelsMatch(
            source: try #require(source.page(at: 1)),
            output: try #require(output.page(at: 1))
        )
    }

    @Test func invalidDestinationLeavesNoPartialFinalAndDoesNotChangeSource() async throws {
        let sourceURL = try fixtureURL()
        let sourceBytes = try Data(contentsOf: sourceURL)
        let missingDirectory = URL.temporaryDirectory
            .appendingPathComponent("LocalOCRCore-missing-\(UUID().uuidString)", isDirectory: true)
        let outputURL = missingDirectory.appendingPathComponent("output.pdf")

        await #expect(throws: LocalOCRError.invalidDestination) {
            try await SearchablePDFWriter().write(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                pageResults: []
            )
        }

        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    @Test func reopensAndValidatesTemporaryOutputBeforeReplacingExistingDestination() async throws {
        let sourceURL = try fixtureURL()
        let location = try temporaryPDFLocation()
        let outputURL = location.outputURL
        let originalDestination = Data("ORIGINAL DESTINATION".utf8)
        try originalDestination.write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let validator = ReopenValidationProbe()

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await SearchablePDFWriter(pdfReader: validator).write(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                pageResults: [
                    PageResult(
                        page: 2,
                        text: "LOCAL OCR OVERLAY",
                        method: .visionOCR,
                        lines: [
                            TextLine(
                                text: "LOCAL OCR OVERLAY",
                                confidence: 0.99,
                                boundingBox: CGRect(x: 0.16, y: 0.18, width: 0.68, height: 0.08)
                            )
                        ],
                        orientation: .up
                    )
                ]
            )
        }

        #expect(validator.observedReadableTemporaryPDF)
        #expect(validator.inspectedURL != sourceURL)
        #expect(validator.inspectedURL != outputURL)
        #expect(try Data(contentsOf: outputURL) == originalDestination)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: outputURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".localocr-") }
        #expect(temporaryFiles.isEmpty)
    }

    @Test func cancellationUsesTheCoreErrorAndLeavesNoOutput() async throws {
        let sourceURL = try fixtureURL()
        let location = try temporaryPDFLocation()
        let outputURL = location.outputURL
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let task = Task {
            try await SearchablePDFWriter().write(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                pageResults: []
            )
        }
        task.cancel()

        await #expect(throws: LocalOCRError.cancelled) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }
}

private final class ReopenValidationProbe: PDFDocumentReading, @unchecked Sendable {
    private let lock = NSLock()
    private var observedURL: URL?
    private var observedReadablePDF = false
    private let realReader = PDFDocumentSource()

    func inspect(_ url: URL) throws -> PDFInspection {
        let inspection = try realReader.inspect(url)
        lock.withLock {
            observedURL = url
            observedReadablePDF = true
        }
        return PDFInspection(
            pages: inspection.pages + 1,
            searchablePages: inspection.searchablePages,
            ocrNeededPages: inspection.ocrNeededPages,
            characters: inspection.characters,
            fullySearchable: inspection.fullySearchable,
            pageDetails: inspection.pageDetails
        )
    }

    func nativeText(in url: URL, pageIndex: Int) throws -> String {
        try realReader.nativeText(in: url, pageIndex: pageIndex)
    }

    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage {
        try realReader.rasterize(url, pageIndex: pageIndex, dpi: dpi)
    }

    var inspectedURL: URL? {
        lock.withLock { observedURL }
    }

    var observedReadableTemporaryPDF: Bool {
        lock.withLock { observedReadablePDF }
    }
}

private func fixtureURL() throws -> URL {
    try #require(
        Bundle.module.url(
            forResource: "overlay-source",
            withExtension: "pdf",
            subdirectory: "Fixtures"
        )
    )
}

private func temporaryPDFLocation() throws -> (directoryURL: URL, outputURL: URL) {
    let directoryURL = URL.temporaryDirectory
        .appendingPathComponent("LocalOCRCore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false
    )
    return (
        directoryURL,
        directoryURL.appendingPathComponent("output.pdf")
    )
}

private func expectSampledPixelsMatch(
    source: PDFPage,
    output: PDFPage,
    channelTolerance: Int = 3
) throws {
    let sourcePixels = try renderedPixels(of: source)
    let outputPixels = try renderedPixels(of: output)
    #expect(sourcePixels.width == outputPixels.width)
    #expect(sourcePixels.height == outputPixels.height)
    guard sourcePixels.width == outputPixels.width,
        sourcePixels.height == outputPixels.height
    else {
        return
    }

    var maximumDifference = 0
    var totalDifference = 0
    var comparedChannels = 0
    for offset in stride(from: 0, to: sourcePixels.bytes.count, by: 4) {
        for channel in 0..<3 {
            let difference = abs(
                Int(sourcePixels.bytes[offset + channel])
                    - Int(outputPixels.bytes[offset + channel])
            )
            maximumDifference = max(maximumDifference, difference)
            totalDifference += difference
            comparedChannels += 1
        }
    }
    let meanDifference = Double(totalDifference) / Double(comparedChannels)
    #expect(maximumDifference <= channelTolerance)
    #expect(meanDifference <= 0.05)
}

private func renderedPixels(of page: PDFPage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
    let bounds = page.bounds(for: .mediaBox)
    let width = Int(bounds.width.rounded(.up))
    let height = Int(bounds.height.rounded(.up))
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let created = bytes.withUnsafeMutableBytes { storage -> Bool in
        guard
            let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return false
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return true
    }
    guard created else {
        throw LocalOCRError.rasterizationFailed(page: 0)
    }
    return (width, height, bytes)
}
