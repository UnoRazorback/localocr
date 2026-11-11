import CoreGraphics
@testable import LocalOCRCore
import Testing

@Suite struct TableRowTextAssemblerTests {
    // Catches the real scanned-COR failure: Vision reads the label column, then the
    // amount column, and plain joining separates every label from its amount.
    @Test func joinsLabelsWithTheirAmountsWhenVisionReadsColumnByColumn() {
        let text = TableRowTextAssembler.text(for: [
            line("MATERIAL", x: 0.10, y: 0.70, width: 0.12),
            line("Flooring", x: 0.10, y: 0.65, width: 0.14),
            line("Base", x: 0.10, y: 0.60, width: 0.06),
            line("SF/LF", x: 0.45, y: 0.70, width: 0.06),
            line("5805", x: 0.45, y: 0.65, width: 0.05),
            line("735", x: 0.45, y: 0.60, width: 0.04),
            line("20,723.85", x: 0.80, y: 0.65, width: 0.10),
            line("3,042.90", x: 0.80, y: 0.60, width: 0.09),
        ])

        #expect(text == "MATERIAL | SF/LF\nFlooring | 5805 | 20,723.85\nBase | 735 | 3,042.90")
    }

    // Catches a change that interleaves two columns of prose line by line.
    @Test func leavesTwoColumnsOfProseInReadingOrder() {
        let text = TableRowTextAssembler.text(for: [
            line("The contractor shall furnish all labor and", x: 0.05, y: 0.80, width: 0.42),
            line("materials required to complete the work.", x: 0.05, y: 0.77, width: 0.40),
            line("The owner may order changes in the work", x: 0.53, y: 0.80, width: 0.42),
            line("within the general scope of the contract.", x: 0.53, y: 0.77, width: 0.41),
        ])

        #expect(text == """
        The contractor shall furnish all labor and
        materials required to complete the work.
        The owner may order changes in the work
        within the general scope of the contract.
        """)
    }

    // Catches a tall logo or stamp swallowing every text line beside it into one row.
    @Test func doesNotLetAnOversizedLineAbsorbTheRowsBesideIt() {
        let text = TableRowTextAssembler.text(for: [
            line("ACME", x: 0.05, y: 0.80, width: 0.25, height: 0.12),
            line("Invoice 1042", x: 0.60, y: 0.89, width: 0.20),
            line("Page 1", x: 0.60, y: 0.84, width: 0.10),
        ])

        #expect(text == "ACME\nInvoice 1042\nPage 1")
    }

    // Catches a long description losing its amount because only short cells were joined.
    @Test func joinsALongDescriptionWithItsAmount() {
        let text = TableRowTextAssembler.text(for: [
            line("One crew, one mechanic and one apprentice, per hour", x: 0.05, y: 0.50, width: 0.50),
            line("Total Labor", x: 0.05, y: 0.45, width: 0.12),
            line("25,740.00", x: 0.80, y: 0.50, width: 0.10),
            line("32,175.00", x: 0.80, y: 0.45, width: 0.10),
        ])

        #expect(text == """
        One crew, one mechanic and one apprentice, per hour | 25,740.00
        Total Labor | 32,175.00
        """)
    }

    // Catches stacked lines in one text block being mistaken for side-by-side cells.
    @Test func keepsStackedLinesOnSeparateLines() {
        let text = TableRowTextAssembler.text(for: [
            line("Subtotal", x: 0.10, y: 0.500, width: 0.10, height: 0.020),
            line("Tax 8%", x: 0.10, y: 0.492, width: 0.08, height: 0.020),
        ])

        #expect(text == "Subtotal\nTax 8%")
    }

    // Catches a crash or dropped text when geometry is missing or degenerate.
    @Test func fallsBackToPlainJoiningWhenGeometryIsUnusable() {
        let text = TableRowTextAssembler.text(for: [
            TextLine(text: "Total", confidence: 1, boundingBox: .zero),
            line("100.00", x: 0.80, y: 0.50, width: 0.10),
        ])

        #expect(text == "Total\n100.00")
    }

    @Test func returnsEmptyTextForNoLines() {
        #expect(TableRowTextAssembler.text(for: []) == "")
    }

    // Catches the engine result drifting away from the assembler.
    @Test func recognitionCandidateTextUsesRowAssembly() {
        let candidate = RecognitionCandidate(
            orientation: .up,
            lines: [
                line("Grand total", x: 0.10, y: 0.30, width: 0.15),
                line("$117,881.23", x: 0.78, y: 0.30, width: 0.14),
            ]
        )

        #expect(candidate.text == "Grand total | $117,881.23")
    }

    private func line(
        _ text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double = 0.02
    ) -> TextLine {
        TextLine(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }
}
