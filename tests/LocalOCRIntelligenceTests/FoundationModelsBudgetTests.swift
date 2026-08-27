@testable import LocalOCRIntelligence
import Testing

@Suite struct FoundationModelsBudgetTests {
    @Test func legacyBudgetLeavesRoomForInstructionsAndResponse() {
        let budget = FoundationModelsBudget.characterBudget(contextSize: 4_096)

        #expect(budget == 4_608)
        #expect(budget > 0)
        #expect(budget <= 8_192)
    }

    @Test func legacyBudgetRemainsPositiveForUnexpectedlySmallContexts() {
        #expect(FoundationModelsBudget.characterBudget(contextSize: 0) == 1)
        #expect(FoundationModelsBudget.characterBudget(contextSize: 1_792) == 1)
    }

    @Test func tokenBudgetRequiresInstructionPromptAndResponseHeadroomToFit() {
        #expect(FoundationModelsBudget.fits(
            instructionTokens: 700,
            promptTokens: 2_300,
            contextSize: 4_096
        ))
        #expect(!FoundationModelsBudget.fits(
            instructionTokens: 700,
            promptTokens: 2_400,
            contextSize: 4_096
        ))
    }

    @Test func overflowRetrySplitsAChunkDeterministicallyWithoutDroppingText() throws {
        let chunk = IntelligenceChunk(page: 7, text: "alpha beta gamma")

        let split = try FoundationModelsBudget.retrySplit(chunk)

        #expect(split == [
            .init(page: 7, text: "alpha be"),
            .init(page: 7, text: "ta gamma")
        ])
        #expect(split.map(\.text).joined() == chunk.text)
    }
}
