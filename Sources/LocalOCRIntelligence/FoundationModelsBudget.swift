public enum FoundationModelsBudget {
    static let instructionHeadroomTokens = 768
    static let responseHeadroomTokens = 1_024
    private static let conservativeCharactersPerToken = 2
    private static let maximumCharacterBudget = 8_192
    private static let worstCaseMarkupExpansion = 6

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

    static func sourceCharacterBudget(
        completePromptCharacterBudget: Int,
        fixedPromptCharacterCount: Int
    ) throws -> Int {
        let charactersAvailable = completePromptCharacterBudget - fixedPromptCharacterCount
        guard charactersAvailable >= worstCaseMarkupExpansion else {
            throw IntelligenceError.contextOverflow
        }
        return charactersAvailable / worstCaseMarkupExpansion
    }

    static func retryChunks(
        _ chunk: IntelligenceChunk,
        sourceCharacterBudget: Int
    ) throws -> [IntelligenceChunk] {
        guard chunk.text.count > 1, sourceCharacterBudget > 0 else {
            throw IntelligenceError.contextOverflow
        }

        let retryBudget = min(sourceCharacterBudget, (chunk.text.count + 1) / 2)
        var remaining = chunk.text
        var chunks: [IntelligenceChunk] = []
        while !remaining.isEmpty {
            let count = min(retryBudget, remaining.count)
            let end = remaining.index(remaining.startIndex, offsetBy: count)
            chunks.append(IntelligenceChunk(page: chunk.page, text: String(remaining[..<end])))
            remaining = String(remaining[end...])
        }
        return chunks
    }

    static func retrySplit(_ chunk: IntelligenceChunk) throws -> [IntelligenceChunk] {
        try retryChunks(chunk, sourceCharacterBudget: Int.max)
    }
}
