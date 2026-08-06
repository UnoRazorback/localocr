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

    @Test func unknownErrorsReplaceUntrustedDetailsWithAPrivacySafeMessage() {
        let untrustedDescriptions = [
            "Unable to inspect /Users/scott/Documents/Private Files/tax return.pdf",
            "Unable to write /Volumes/Archive Drive/client records.pdf",
            "Could not open file:///tmp/Private%20Notes/meeting.txt",
            "Authorization: Bearer top-secret-token",
            "Document content: Client SSN 123-45-6789"
        ]

        for description in untrustedDescriptions {
            let presentation = StudioErrorPresentation.present(
                UntrustedLocalizedError(description: description)
            )

            #expect(presentation.title == "Couldn’t Process Document")
            #expect(presentation.details == "Technical details are hidden to protect your privacy.")
            #expect(presentation.details != description)
        }
    }
}

private struct UntrustedLocalizedError: LocalizedError {
    let description: String

    var errorDescription: String? { description }
}
