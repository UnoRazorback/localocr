import Foundation
import LocalOCRCore
import Testing

@Test func searchableOutputNeverOverwrites() {
    let source = URL(fileURLWithPath: "/tmp/report.pdf")
    let occupied: Set<String> = ["/tmp/report_searchable.pdf"]

    let output = OutputNaming.searchablePDFURL(for: source) {
        occupied.contains($0.path)
    }

    #expect(output.lastPathComponent == "report_searchable_2.pdf")
}
