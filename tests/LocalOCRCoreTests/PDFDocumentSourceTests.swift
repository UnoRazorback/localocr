import Foundation
import LocalOCRCore
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
        PageInspection(page: 1, characters: 54, searchable: true),
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

@Test func inspectionRejectsMissingAndInvalidPDFs() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LocalOCRCore-missing.pdf")
    #expect(throws: LocalOCRError.fileNotFound) {
        try PDFDocumentSource().inspect(missing)
    }

    let invalid = URL.temporaryDirectory.appendingPathComponent("LocalOCRCore-invalid-\(UUID().uuidString).pdf")
    try Data("not a PDF".utf8).write(to: invalid)
    defer { try? FileManager.default.removeItem(at: invalid) }

    #expect(throws: LocalOCRError.unreadablePDF) {
        try PDFDocumentSource().inspect(invalid)
    }
}

@Test func rasterizesOnePDFPageAtRequestedDPI() throws {
    let page = try #require(PDFDocument(url: Fixtures.mixedPDF)?.page(at: 0))
    let bounds = page.bounds(for: .mediaBox)
    let image = try PDFDocumentSource().rasterize(Fixtures.mixedPDF, pageIndex: 0, dpi: 250)

    #expect(abs(image.width - Int((bounds.width * 250 / 72).rounded())) <= 1)
    #expect(abs(image.height - Int((bounds.height * 250 / 72).rounded())) <= 1)
    #expect(image.colorSpace?.model == .rgb)
}

@Test func rasterizationRejectsOutOfBoundsPage() {
    #expect(throws: LocalOCRError.pageOutOfBounds(page: 3, total: 2)) {
        try PDFDocumentSource().rasterize(Fixtures.mixedPDF, pageIndex: 2, dpi: 250)
    }
}
