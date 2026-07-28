import CoreGraphics
import Darwin
import Foundation
@testable import LocalOCRCore
import PDFKit
import Testing

private enum Fixtures {
    static let mixedPDF = fixture(named: "mixed")
    static let imageOnlyPDF = fixture(named: "image-only")
    static let boundary19PDF = fixture(named: "boundary-19")
    static let boundary20PDF = fixture(named: "boundary-20")

    private static func fixture(named name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Fixtures") else {
            fatalError("Missing test fixture: \(name).pdf")
        }
        return url
    }
}

@Test func inspectsMixedPDF() throws {
    let result = try PDFDocumentSource().inspect(Fixtures.mixedPDF)

    #expect(result.pages == 2)
    #expect(result.searchablePages == [1])
    #expect(result.ocrNeededPages == [2])
    #expect(result.fullySearchable == false)
    #expect(result.pageDetails == [
        PageInspection(page: 1, characters: 66, searchable: true),
        PageInspection(page: 2, characters: 0, searchable: false),
    ])
}

@Test func inspectsImageOnlyPDFAsNeedingOCR() throws {
    let result = try PDFDocumentSource().inspect(Fixtures.imageOnlyPDF)

    #expect(result.pages == 2)
    #expect(result.searchablePages == [])
    #expect(result.ocrNeededPages == [1, 2])
    #expect(result.characters == 0)
    #expect(result.fullySearchable == false)
}

@Test func inspectionUsesTrimmedNativeTextThreshold() throws {
    let source = PDFDocumentSource()

    let nineteenCharacters = try source.inspect(Fixtures.boundary19PDF)
    let twentyCharacters = try source.inspect(Fixtures.boundary20PDF)

    #expect(nineteenCharacters.pageDetails == [PageInspection(page: 1, characters: 19, searchable: false)])
    #expect(nineteenCharacters.ocrNeededPages == [1])
    #expect(twentyCharacters.pageDetails == [PageInspection(page: 1, characters: 20, searchable: true)])
    #expect(twentyCharacters.searchablePages == [1])
}

@Test func nativeCharacterCountUsesUnicodeScalarsAtDecomposedAccentBoundary() {
    let nineteenScalars = String(repeating: "x", count: 17) + "e\u{301}"
    let twentyScalars = String(repeating: "x", count: 18) + "e\u{301}"

    #expect(
        PDFDocumentSource.nativeCharacterCount(in: nineteenScalars) == 19
    )
    #expect(
        PDFDocumentSource.nativeCharacterCount(in: twentyScalars) == 20
    )
    #expect(
        PDFDocumentSource.nativeCharacterCount(in: nineteenScalars)
            < PDFDocumentSource.minimumNativeCharacters
    )
    #expect(
        PDFDocumentSource.nativeCharacterCount(in: twentyScalars)
            >= PDFDocumentSource.minimumNativeCharacters
    )
}

@Test func inspectionRejectsMissingPDF() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LocalOCRCore-missing.pdf")
    #expect(throws: LocalOCRError.fileNotFound) {
        try PDFDocumentSource().inspect(missing)
    }
}

@Test func inspectionRejectsInvalidPDFWhileContainingCoreGraphicsDiagnostic() throws {
    let invalid = URL.temporaryDirectory.appendingPathComponent("LocalOCRCore-invalid-\(UUID().uuidString).pdf")
    try Data("%PDF-1.7\n".utf8).write(to: invalid)
    defer { try? FileManager.default.removeItem(at: invalid) }

    let standardError = capturedStandardError {
        #expect(throws: LocalOCRError.unreadablePDF) {
            try PDFDocumentSource().inspect(invalid)
        }
    }
    #expect(standardError.contains("CoreGraphics PDF has logged an error"))
}

@Test func rasterizesOnePDFPageAtRequestedDPI() throws {
    let page = try #require(PDFDocument(url: Fixtures.mixedPDF)?.page(at: 0))
    let bounds = page.bounds(for: .mediaBox)
    let image = try PDFDocumentSource().rasterize(Fixtures.mixedPDF, pageIndex: 0, dpi: 250)

    #expect(abs(image.width - Int((bounds.width * 250 / 72).rounded())) <= 1)
    #expect(abs(image.height - Int((bounds.height * 250 / 72).rounded())) <= 1)
    #expect(image.colorSpace?.model == .rgb)
}

@Test func rasterizesAllQuarterTurnsWithoutClippingNonZeroMediaBoxContent() throws {
    let fixture = try makeQuarterTurnRasterFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

    let expectedDimensions = [
        (width: 500, height: 300),
        (width: 300, height: 500),
        (width: 500, height: 300),
        (width: 300, height: 500),
    ]
    for (pageIndex, expected) in expectedDimensions.enumerated() {
        let image = try PDFDocumentSource().rasterize(
            fixture.pdfURL,
            pageIndex: pageIndex,
            dpi: 72
        )

        #expect(image.width == expected.width)
        #expect(image.height == expected.height)
        let colors = try rasterMarkerCounts(in: image)
        #expect(colors.red > 2_200)
        #expect(colors.green > 2_200)
        #expect(colors.blue > 2_200)
        #expect(colors.black > 2_200)
    }
}

@Test func rasterizationRejectsOutOfBoundsPage() {
    #expect(throws: LocalOCRError.pageOutOfBounds(page: 3, total: 2)) {
        try PDFDocumentSource().rasterize(Fixtures.mixedPDF, pageIndex: 2, dpi: 250)
    }
}

private func makeQuarterTurnRasterFixture() throws -> (
    directoryURL: URL,
    pdfURL: URL
) {
    let directoryURL = URL.temporaryDirectory
        .appendingPathComponent(
            "PDFDocumentSourceTests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false
    )
    let unrotatedURL = directoryURL.appendingPathComponent("unrotated.pdf")
    let rotatedURL = directoryURL.appendingPathComponent("quarter-turns.pdf")
    let mediaBox = CGRect(x: 100, y: 50, width: 500, height: 300)
    guard let consumer = CGDataConsumer(url: unrotatedURL as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil)
    else {
        throw LocalOCRError.invalidDestination
    }

    for _ in 0..<4 {
        context.beginPDFPage(
            [
                kCGPDFContextMediaBox as String:
                    pdfDocumentSourceRectangleData(mediaBox),
            ] as CFDictionary
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 100, y: 50, width: 60, height: 40))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 540, y: 50, width: 60, height: 40))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 310, width: 60, height: 40))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 540, y: 310, width: 60, height: 40))
        context.endPDFPage()
    }
    context.closePDF()

    guard let document = PDFDocument(url: unrotatedURL) else {
        throw LocalOCRError.unreadablePDF
    }
    for (pageIndex, rotation) in [0, 90, 180, 270].enumerated() {
        guard let page = document.page(at: pageIndex) else {
            throw LocalOCRError.outputValidationFailed
        }
        page.rotation = rotation
    }
    guard document.write(to: rotatedURL) else {
        throw LocalOCRError.invalidDestination
    }
    return (directoryURL, rotatedURL)
}

private func pdfDocumentSourceRectangleData(_ rectangle: CGRect) -> CFData {
    var rectangle = rectangle
    return withUnsafeBytes(of: &rectangle) {
        Data($0) as CFData
    }
}

private func rasterMarkerCounts(in image: CGImage) throws -> (
    red: Int,
    green: Int,
    blue: Int,
    black: Int
) {
    guard let providerData = image.dataProvider?.data else {
        throw LocalOCRError.rasterizationFailed(page: 0)
    }
    let bytes = providerData as Data
    var red = 0
    var green = 0
    var blue = 0
    var black = 0
    bytes.withUnsafeBytes { storage in
        let pixels = storage.bindMemory(to: UInt8.self)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4
                let redChannel = pixels[offset]
                let greenChannel = pixels[offset + 1]
                let blueChannel = pixels[offset + 2]
                if redChannel > 200, greenChannel < 80, blueChannel < 80 {
                    red += 1
                } else if greenChannel > 200,
                          redChannel < 80,
                          blueChannel < 80
                {
                    green += 1
                } else if blueChannel > 200,
                          redChannel < 80,
                          greenChannel < 80
                {
                    blue += 1
                } else if redChannel < 80,
                          greenChannel < 80,
                          blueChannel < 80
                {
                    black += 1
                }
            }
        }
    }
    return (red, green, blue, black)
}

private func capturedStandardError(_ operation: () -> Void) -> String {
    let pipe = Pipe()
    let originalStandardError = dup(STDERR_FILENO)
    precondition(originalStandardError != -1, "Could not duplicate standard error")
    fflush(stderr)
    precondition(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) != -1, "Could not redirect standard error")

    var restored = false
    defer {
        if !restored {
            fflush(stderr)
            _ = dup2(originalStandardError, STDERR_FILENO)
            close(originalStandardError)
            pipe.fileHandleForWriting.closeFile()
        }
    }

    operation()
    fflush(stderr)
    precondition(dup2(originalStandardError, STDERR_FILENO) != -1, "Could not restore standard error")
    close(originalStandardError)
    pipe.fileHandleForWriting.closeFile()
    restored = true
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}
