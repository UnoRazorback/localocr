public enum FoundationModelsBudget {
    static let instructionHeadroomTokens = 768
    static let responseHeadroomTokens = 1_024
    private static let conservativeCharactersPerToken = 2
    private static let maximumCharacterBudget = 8_192

    /// A deterministic fallback for macOS 26.0-26.3, where token counting is unavailable.
    public static func characterBudget(contextSize: Int) -> Int {
        let reservedTokens = instructionHeadroomTokens + responseHeadroomTokens
        guard contextSize > reservedTokens else { return 1 }

        let usableTokens = min(
            contextSize - reservedTokens,
            maximumCharacterBudget / conservativeCharactersPerToken
        )
        return max(1, usableTokens * conservativeCharactersPerToken)
    }

    static func fits(instructionTokens: Int, promptTokens: Int, contextSize: Int) -> Bool {
        guard instructionTokens >= 0, promptTokens >= 0, contextSize > 0 else {
            return false
        }

        let availableForPrompt = contextSize - responseHeadroomTokens - instructionTokens
        return availableForPrompt >= 0 && promptTokens <= availableForPrompt
    }

    static func retrySplit(_ chunk: IntelligenceChunk) throws -> [IntelligenceChunk] {
        guard chunk.text.count > 1 else {
            throw IntelligenceError.contextOverflow
        }

        let firstCount = (chunk.text.count + 1) / 2
        let splitIndex = chunk.text.index(chunk.text.startIndex, offsetBy: firstCount)
        return [
            IntelligenceChunk(page: chunk.page, text: String(chunk.text[..<splitIndex])),
            IntelligenceChunk(page: chunk.page, text: String(chunk.text[splitIndex...]))
        ]
    }
}
