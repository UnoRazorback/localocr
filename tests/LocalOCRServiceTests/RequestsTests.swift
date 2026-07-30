import Foundation
import LocalOCRService
import Testing

@Test func pdfMetadataRequestsPreserveTheirFileInputs() {
    let pageCount = PageCountRequest(fileURL: URL(fileURLWithPath: "/tmp/pages.pdf"))
    let inspection = InspectPDFRequest(fileURL: URL(fileURLWithPath: "/tmp/inspect.pdf"))

    #expect(pageCount.fileURL.path == "/tmp/pages.pdf")
    #expect(inspection.fileURL.path == "/tmp/inspect.pdf")
}
