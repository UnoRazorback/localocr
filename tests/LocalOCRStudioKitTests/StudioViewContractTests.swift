import Foundation
@testable import LocalOCRStudioKit
import Testing

@Suite struct StudioViewContractTests {
    @Test func searchablePDFBusyStateDisablesResultFooterActions() {
        let availability = StudioResultActionAvailability(
            isCreatingSearchablePDF: true
        )

        #expect(availability.footerActionsAreEnabled == false)
    }

    @Test func emptyInvitesOneLocalDocumentWithoutOfferingActions() {
        let contract = StudioViewContract(state: .empty)

        #expect(contract.primaryTitle == "Drop a document here")
        #expect(contract.statusText == "PDF or image • Processed locally on this Mac.")
        #expect(contract.canCopy == false)
        #expect(contract.canSaveText == false)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == false)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == false)
    }

    @Test func processingNamesTheDocumentAndKeepsTheLocalProcessingPromiseVisible() {
        let sourceURL = URL(fileURLWithPath: "/tmp/Client Notes.pdf")
        let contract = StudioViewContract(
            state: .processing(
                sourceURL: sourceURL,
                progress: .recognizing(page: 2, total: 4)
            )
        )

        #expect(contract.primaryTitle == "Client Notes.pdf")
        #expect(contract.statusText == "Recognizing page 2 of 4 • Processing locally on this Mac.")
        #expect(contract.canCopy == false)
        #expect(contract.canSaveText == false)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == false)
        #expect(contract.canCancel == true)
        #expect(contract.canRetry == false)
    }

    @Test func pdfResultOffersEveryDocumentAction() {
        let contract = StudioViewContract(
            state: .result(result(kind: .pdf, pageCount: 4))
        )

        #expect(contract.primaryTitle == "Quarterly Report.pdf")
        #expect(contract.statusText == "4 pages • 3 already searchable • 1 recognized")
        #expect(contract.canCopy == true)
        #expect(contract.canSaveText == true)
        #expect(contract.canCreateSearchablePDF == true)
        #expect(contract.canProcessAnotherDocument == true)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == false)
    }

    @Test func imageResultDoesNotOfferSearchablePDF() {
        let contract = StudioViewContract(
            state: .result(
                result(
                    kind: .image,
                    pageCount: 1,
                    searchablePages: 0,
                    ocrNeededPages: 1
                )
            )
        )

        #expect(contract.primaryTitle == "Quarterly Report.pdf")
        #expect(contract.statusText == "Image • Text ready")
        #expect(contract.canCopy == true)
        #expect(contract.canSaveText == true)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == true)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == false)
    }

    @Test func failureOffersRecoveryWithoutDocumentActions() {
        let sourceURL = URL(fileURLWithPath: "/tmp/damaged.pdf")
        let error = StudioPresentedError(
            title: "Couldn’t Read Document",
            message: "This document appears to be damaged or unreadable.",
            details: nil
        )
        let contract = StudioViewContract(state: .failure(sourceURL: sourceURL, error))

        #expect(contract.primaryTitle == "Couldn’t Read Document")
        #expect(contract.statusText == "This document appears to be damaged or unreadable.")
        #expect(contract.canCopy == false)
        #expect(contract.canSaveText == false)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == false)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == true)
    }
}

private func result(
    kind: StudioDocumentKind,
    pageCount: Int,
    searchablePages: Int = 3,
    ocrNeededPages: Int = 1
) -> StudioDocumentResult {
    StudioDocumentResult(
        sourceURL: URL(fileURLWithPath: "/tmp/Quarterly Report.pdf"),
        sourceSHA256: "fixture-hash",
        kind: kind,
        pageCount: pageCount,
        searchablePages: searchablePages,
        ocrNeededPages: ocrNeededPages,
        text: "Recognized text",
        failedPages: []
    )
}
