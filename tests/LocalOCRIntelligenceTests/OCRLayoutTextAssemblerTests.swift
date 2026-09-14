@testable import LocalOCRIntelligence
import LocalOCRService
import Testing

@Suite struct OCRLayoutTextAssemblerTests {
    // Catches a change that flattens independent Vision lines instead of retaining their table row.
    @Test func assemblesOverlappingLinesIntoOrderedTableRows() {
        let text = OCRLayoutTextAssembler.text(
            for: [
                line("$2,000.00", x: 0.72, y: 0.64, width: 0.16, height: 0.08),
                line("Change order", x: 0.05, y: 0.84, width: 0.25, height: 0.08),
                line("Lift and delivery", x: 0.29, y: 0.65, width: 0.31, height: 0.08),
                line("Equipment", x: 0.05, y: 0.63, width: 0.16, height: 0.10),
                line("Approval required", x: 0.05, y: 0.42, width: 0.35, height: 0.08),
            ],
            fallback: "flat OCR text"
        )

        #expect(text == "Change order\nEquipment | Lift and delivery | $2,000.00\nApproval required")
    }

    // Catches a change that treats distant vertical content as cells in one row.
    @Test func keepsVerticallySeparatedLinesOnSeparateRows() {
        let text = OCRLayoutTextAssembler.text(
            for: [
                line("Bottom", x: 0.10, y: 0.10, width: 0.20, height: 0.08),
                line("Top", x: 0.70, y: 0.80, width: 0.20, height: 0.08),
            ],
            fallback: "flat OCR text"
        )

        #expect(text == "Top\nBottom")
    }

    // Catches a change that trusts an unusable geometry value instead of retaining OCR text.
    @Test func returnsFallbackForNonFiniteGeometry() {
        let text = OCRLayoutTextAssembler.text(
            for: [line("Equipment", x: .nan, y: 0.60, width: 0.20, height: 0.08)],
            fallback: "flat OCR text"
        )

        #expect(text == "flat OCR text")
    }

    // Catches a change that accepts a line rectangle extending past the normalized page boundary.
    @Test func returnsFallbackForOutOfBoundsGeometry() {
        let text = OCRLayoutTextAssembler.text(
            for: [line("Equipment", x: 0.90, y: 0.60, width: 0.20, height: 0.08)],
            fallback: "flat OCR text"
        )

        #expect(text == "flat OCR text")
    }
}

private func line(
    _ text: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double
) -> OCRLineResponse {
    OCRLineResponse(
        text: text,
        confidence: 0.99,
        x: x,
        y: y,
        width: width,
        height: height
    )
}
