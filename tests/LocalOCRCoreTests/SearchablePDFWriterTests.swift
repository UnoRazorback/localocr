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
                            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
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
        let rotatedPage = try #require(output.page(at: 3))
        let rotatedSelection = try #require(
            output.findString("ROTATED OCR OVERLAY", withOptions: []).first
        )
        let rotatedBounds = rotatedSelection.bounds(for: rotatedPage)
        #expect(rotatedBounds.minX > 430)
        #expect(rotatedBounds.minY > 45)
        #expect(rotatedBounds.minY < 60)
        #expect(rotatedBounds.height > rotatedBounds.width * 5)
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
                            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
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

    @Test func preservesDifferingPageBoxesAndCroppedAppearance() async throws {
        let location = try temporaryPDFLocation()
        let sourceURL = location.directoryURL.appendingPathComponent("cropped-source.pdf")
        let outputURL = location.outputURL
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        try makeCroppedSource(at: sourceURL)

        _ = try await SearchablePDFWriter().write(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            pageResults: [
                PageResult(
                    page: 1,
                    text: "CROPPED OCR OVERLAY",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "CROPPED OCR OVERLAY",
                            confidence: 0.99,
                            boundingBox: CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.1)
                        )
                    ],
                    orientation: .up
                )
            ]
        )

        let sourceDocument = try #require(PDFDocument(url: sourceURL))
        let outputDocument = try #require(PDFDocument(url: outputURL))
        let sourcePage = try #require(sourceDocument.page(at: 0))
        let outputPage = try #require(outputDocument.page(at: 0))
        for displayBox in [
            PDFDisplayBox.mediaBox,
            .cropBox,
            .bleedBox,
            .trimBox,
            .artBox,
        ] {
            #expect(outputPage.bounds(for: displayBox) == sourcePage.bounds(for: displayBox))
        }
        try expectSampledPixelsMatch(
            source: sourcePage,
            output: outputPage,
            displayBox: .cropBox
        )
    }

    @Test func preservesNonZeroMediaBoxOriginAndPlacesOCRRelativeToIt() async throws {
        let location = try temporaryPDFLocation()
        let sourceURL = location.directoryURL.appendingPathComponent("offset-source.pdf")
        let outputURL = location.outputURL
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        try makeNonZeroOriginSource(at: sourceURL)

        _ = try await SearchablePDFWriter().write(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            pageResults: [
                PageResult(
                    page: 1,
                    text: "NONZERO ORIGIN OCR",
                    method: .visionOCR,
                    lines: [
                        TextLine(
                            text: "NONZERO ORIGIN OCR",
                            confidence: 0.99,
                            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
                        )
                    ],
                    orientation: .up
                )
            ]
        )

        let sourceDocument = try #require(PDFDocument(url: sourceURL))
        let outputDocument = try #require(PDFDocument(url: outputURL))
        let sourcePage = try #require(sourceDocument.page(at: 0))
        let outputPage = try #require(outputDocument.page(at: 0))
        #expect(
            sourcePage.bounds(for: .mediaBox)
                == CGRect(x: 100, y: 50, width: 500, height: 300)
        )
        for displayBox in [
            PDFDisplayBox.mediaBox,
            .cropBox,
            .bleedBox,
            .trimBox,
            .artBox,
        ] {
            #expect(outputPage.bounds(for: displayBox) == sourcePage.bounds(for: displayBox))
        }
        try expectSampledPixelsMatch(source: sourcePage, output: outputPage)

        let selection = try #require(
            outputDocument.findString("NONZERO ORIGIN OCR", withOptions: []).first
        )
        let selectionBounds = selection.bounds(for: outputPage)
        #expect(selectionBounds.minX >= 150)
        #expect(selectionBounds.minX < 151)
        #expect(selectionBounds.maxX <= 251)
        #expect(selectionBounds.minY >= 80)
        #expect(selectionBounds.maxY <= 110)
        #expect(selectionBounds.width > selectionBounds.height * 5)
    }

    @Test func rejectsMissingOCRTextEvenWhenVisionPageHasUnrelatedNativeText() async throws {
        let sourceURL = try fixtureURL()
        let location = try temporaryPDFLocation()
        let outputURL = location.outputURL
        let originalDestination = Data("ORIGINAL DESTINATION".utf8)
        try originalDestination.write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }

        await #expect(throws: LocalOCRError.outputValidationFailed) {
            try await SearchablePDFWriter().write(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                pageResults: [
                    PageResult(
                        page: 1,
                        text: "EXPECTED OCR TEXT",
                        method: .visionOCR,
                        lines: [
                            TextLine(
                                text: "EXPECTED OCR TEXT",
                                confidence: 0.99,
                                boundingBox: .zero
                            )
                        ],
                        orientation: .up
                    )
                ]
            )
        }

        #expect(try Data(contentsOf: outputURL) == originalDestination)
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

private func makeCroppedSource(at outputURL: URL) throws {
    let fixture = try #require(PDFDocument(url: fixtureURL()))
    let fixturePage = try #require(fixture.page(at: 2)?.copy() as? PDFPage)
    fixturePage.setBounds(
        CGRect(x: 60, y: 45, width: 320, height: 180),
        for: .cropBox
    )
    fixturePage.setBounds(
        CGRect(x: 55, y: 40, width: 330, height: 190),
        for: .bleedBox
    )
    fixturePage.setBounds(
        CGRect(x: 70, y: 55, width: 280, height: 150),
        for: .trimBox
    )
    fixturePage.setBounds(
        CGRect(x: 80, y: 65, width: 250, height: 120),
        for: .artBox
    )
    let document = PDFDocument()
    document.insert(fixturePage, at: 0)
    #expect(document.write(to: outputURL))
}

private func makeNonZeroOriginSource(at outputURL: URL) throws {
    let mediaBox = CGRect(x: 100, y: 50, width: 500, height: 300)
    guard let consumer = CGDataConsumer(url: outputURL as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: nil, nil)
    else {
        throw LocalOCRError.invalidDestination
    }
    context.beginPDFPage(
        [
            kCGPDFContextMediaBox as String: pdfRectangleData(mediaBox),
            kCGPDFContextCropBox as String: pdfRectangleData(mediaBox),
            kCGPDFContextBleedBox as String: pdfRectangleData(
                CGRect(x: 110, y: 55, width: 480, height: 290)
            ),
            kCGPDFContextTrimBox as String: pdfRectangleData(
                CGRect(x: 120, y: 60, width: 460, height: 280)
            ),
            kCGPDFContextArtBox as String: pdfRectangleData(
                CGRect(x: 130, y: 65, width: 440, height: 270)
            ),
        ] as CFDictionary
    )
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(mediaBox)
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 130, y: 90, width: 160, height: 120))
    context.setFillColor(CGColor(red: 0.2, green: 0.75, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 320, y: 180, width: 220, height: 30))
    context.setFillColor(CGColor(red: 1, green: 0.45, blue: 0.15, alpha: 1))
    context.fillEllipse(in: CGRect(x: 400, y: 70, width: 120, height: 90))
    context.endPDFPage()
    context.closePDF()
}

private func pdfRectangleData(_ rectangle: CGRect) -> CFData {
    var rectangle = rectangle
    return withUnsafeBytes(of: &rectangle) {
        Data($0) as CFData
    }
}

private func expectSampledPixelsMatch(
    source: PDFPage,
    output: PDFPage,
    displayBox: PDFDisplayBox = .mediaBox,
    channelTolerance: Int = 3
) throws {
    let sourcePixels = try renderedPixels(of: source, displayBox: displayBox)
    let outputPixels = try renderedPixels(of: output, displayBox: displayBox)
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

private func renderedPixels(
    of page: PDFPage,
    displayBox: PDFDisplayBox
) throws -> (width: Int, height: Int, bytes: [UInt8]) {
    let bounds = page.bounds(for: displayBox)
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
        page.draw(with: displayBox, to: context)
        return true
    }
    guard created else {
        throw LocalOCRError.rasterizationFailed(page: 0)
    }
    return (width, height, bytes)
}
