import CoreGraphics
import Foundation
import ImageIO
import LocalOCRCore
@testable import LocalOCRService
import Testing

@Suite struct AmountCheckTests {
    // Catches the check not reaching the caller: no second read, no mark in the text, or no count.
    @Test func marksAmountsTheSecondReadDisagreesWithAndReportsTheCount() async throws {
        let reads = ReadRecorder()
        let service = amountService(reads: reads)
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let response = try await service.ocrPDF(
            PDFOCRRequest(fileURL: sourceURL, includeLines: true, verifyAmounts: true, usesCache: false)
        )

        #expect(response.pages.map(\.text) == [
            embeddedPageText,
            "Contract Sum to Date | 25,740.00 [second read: 25,748.00]\nRetainage | 1,287.00",
        ])
        #expect(response.amountCheck == AmountCheckResponse(
            secondReadDPI: 350, flaggedAmounts: 1, uncheckedPages: []
        ))
        // Line details stay the first read, exactly as recognized.
        #expect(response.pages[1].lines?.map(\.text) == [
            "Contract Sum to Date", "25,740.00", "Retainage", "1,287.00",
        ])
        // Only the recognized page is read again; the embedded-text page is exact already.
        #expect(reads.values == [Read(page: 2, dpi: 250), Read(page: 2, dpi: 350)])
    }

    // Catches an unrequested check changing output or costing a second read.
    @Test func readsOnceAndAddsNothingWhenTheCheckIsNotRequested() async throws {
        let reads = ReadRecorder()
        let service = amountService(reads: reads)
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let response = try await service.ocrPDF(PDFOCRRequest(fileURL: sourceURL, usesCache: false))

        #expect(response.pages[1].text == "Contract Sum to Date | 25,740.00\nRetainage | 1,287.00")
        #expect(response.amountCheck == nil)
        #expect(reads.values == [Read(page: 2, dpi: 250)])
        let json = String(decoding: ResponseEncoding.encode(response), as: UTF8.self)
        #expect(!json.contains("amount_check"))
    }

    // Catches a failed second read being reported as "nothing to flag".
    @Test func reportsAPageAsUncheckedWhenTheSecondReadFails() async throws {
        let service = amountService(reads: ReadRecorder(), failingDPI: 350)
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let response = try await service.ocrPDF(
            PDFOCRRequest(fileURL: sourceURL, verifyAmounts: true, usesCache: false)
        )

        #expect(response.pages[1].text == "Contract Sum to Date | 25,740.00\nRetainage | 1,287.00")
        #expect(response.failedPages.isEmpty)
        #expect(response.amountCheck == AmountCheckResponse(
            secondReadDPI: 350, flaggedAmounts: 0, uncheckedPages: [2]
        ))
    }

    // Catches the batch tool dropping the option or the result field.
    @Test func batchCarriesTheCheckThroughInItsWireFormat() async throws {
        let service = amountService(reads: ReadRecorder())
        let sourceURL = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let response = await service.ocrPDFBatch(
            try BatchOCRRequest(fileURLs: [sourceURL], verifyAmounts: true, usesCache: false)
        )

        let json = String(decoding: ResponseEncoding.encode(response), as: UTF8.self)
        #expect(json.contains(
            #""amount_check":{"flagged_amounts":1,"second_read_dpi":350,"unchecked_pages":[]}"#
        ))
    }
}

// Long enough that the engine does not look at the pixels of page 1.
private let embeddedPageText = String(repeating: "embedded page text ", count: 30)

private struct Read: Equatable {
    let page: Int
    let dpi: Int
}

private final class ReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Read] = []

    func record(_ read: Read) {
        lock.lock()
        storage.append(read)
        lock.unlock()
    }

    var values: [Read] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func amountService(reads: ReadRecorder, failingDPI: Int? = nil) -> LocalOCRService {
    LocalOCRService(
        pdfSourceFactory: { AmountPDFSource(reads: reads, failingDPI: failingDPI) },
        processorFactory: { _ in
            OCRProcessor(
                pdfSource: AmountPDFSource(reads: reads, failingDPI: failingDPI),
                recognizer: AmountRecognizer(),
                cache: nil
            )
        },
        writerFactory: { fatalError("Not used") },
        imageSourceFactory: { ImageDocumentSource() }
    )
}

/// Page 1 has full embedded text; page 2 is a scan.
private struct AmountPDFSource: PDFDocumentReading {
    let reads: ReadRecorder
    let failingDPI: Int?

    func inspect(_ url: URL) throws -> PDFInspection {
        PDFInspection(
            pages: 2,
            searchablePages: [1],
            ocrNeededPages: [2],
            characters: 500,
            fullySearchable: false,
            pageDetails: [
                PageInspection(page: 1, characters: 500, searchable: true),
                PageInspection(page: 2, characters: 0, searchable: false),
            ]
        )
    }

    func nativeText(in url: URL, pageIndex: Int) throws -> String {
        embeddedPageText
    }

    func rasterize(_ url: URL, pageIndex: Int, dpi: Int) throws -> CGImage {
        reads.record(Read(page: pageIndex + 1, dpi: dpi))
        if dpi == failingDPI {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let image = context?.makeImage() else {
            throw LocalOCRError.rasterizationFailed(page: pageIndex + 1)
        }
        return image
    }
}

/// Misreads one digit at the first resolution, as Vision does at full confidence.
private struct AmountRecognizer: TextRecognizing {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        RecognitionCandidate(orientation: orientation, lines: [
            line("Contract Sum to Date", x: 0.10, y: 0.60, width: 0.30),
            line(settings.dpi == 250 ? "25,740.00" : "25,748.00", x: 0.80, y: 0.60, width: 0.10),
            line("Retainage", x: 0.10, y: 0.55, width: 0.12),
            line("1,287.00", x: 0.80, y: 0.55, width: 0.09),
        ])
    }

    private func line(_ text: String, x: Double, y: Double, width: Double) -> TextLine {
        TextLine(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: 0.02))
    }
}

private func temporaryPDF() throws -> URL {
    let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("fixture".utf8).write(to: url)
    return url
}
