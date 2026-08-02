import Foundation
import LocalOCRCore
import LocalOCRStudioKit
import Testing

@Suite struct StudioErrorPresentationTests {
    @Test func mapsEverySupportedErrorToAPlainLanguageTitle() {
        let cases: [(any Error, String)] = [
            (LocalOCRError.fileNotFound, "File Not Found"),
            (LocalOCRError.unsupportedFormat("txt"), "Unsupported File"),
            (LocalOCRError.imageDecodeFailed, "Couldn’t Read Document"),
            (LocalOCRError.permissionDenied, "Permission Needed"),
            (LocalOCRError.invalidPageSelection("0"), "OCR Failed"),
            (LocalOCRError.pageOutOfBounds(page: 3, total: 2), "OCR Failed"),
            (LocalOCRError.unreadablePDF, "Couldn’t Read Document"),
            (LocalOCRError.rasterizationFailed(page: 2), "OCR Failed"),
            (LocalOCRError.recognitionFailed(page: 2, message: "Vision failed"), "OCR Failed"),
            (LocalOCRError.insufficientDiskSpace, "Not Enough Disk Space"),
            (LocalOCRError.invalidDestination, "Choose Another Destination"),
            (LocalOCRError.outputExists, "Output Already Exists"),
            (LocalOCRError.outputValidationFailed, "Choose Another Destination"),
            (LocalOCRError.cancelled, "Operation Cancelled"),
            (StudioClientError.sourceChanged, "Document Changed")
        ]

        for (error, expectedTitle) in cases {
            #expect(StudioErrorPresentation.present(error).title == expectedTitle)
        }
    }

    @Test func unknownErrorsUseASanitizedTechnicalDetail() {
        let presentation = StudioErrorPresentation.present(LeakyError())

        #expect(presentation.title == "Couldn’t Process Document")
        #expect(presentation.details != nil)
        #expect(!presentation.details!.contains("\n"))
        #expect(!presentation.details!.contains("/Users/"))
    }
}

private struct LeakyError: LocalizedError {
    var errorDescription: String? {
        "Unable to inspect /Users/scott/Documents/private.pdf\nFirst page source content"
    }
}
