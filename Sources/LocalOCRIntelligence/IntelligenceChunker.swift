public struct IntelligenceChunk: Sendable, Equatable {
    public let page: Int
    public let text: String

    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }
}

public enum IntelligenceChunker {
    /// Produces chunks that are no larger than `characterBudget` characters.
    ///
    /// - Precondition: `characterBudget` is greater than zero.
    public static func chunks(document: IntelligenceDocument, characterBudget: Int) -> [IntelligenceChunk] {
        precondition(characterBudget > 0, "characterBudget must be greater than zero")
        return uncheckedChunks(document: document, characterBudget: characterBudget)
    }

    static func validatedChunks(document: IntelligenceDocument, characterBudget: Int) throws -> [IntelligenceChunk] {
        guard characterBudget > 0 else {
            throw IntelligenceError.contextOverflow
        }

        return uncheckedChunks(document: document, characterBudget: characterBudget)
    }

    private static func uncheckedChunks(document: IntelligenceDocument, characterBudget: Int) -> [IntelligenceChunk] {
        return document.pages.flatMap { page in
            split(page.text, characterBudget: characterBudget).map {
                IntelligenceChunk(page: page.number, text: $0)
            }
        }
    }

    private static func split(_ text: String, characterBudget: Int) -> [String] {
        var remaining = text
        var fragments: [String] = []

        while !remaining.isEmpty {
            guard remaining.count > characterBudget else {
                fragments.append(remaining)
                break
            }

            let limit = remaining.index(remaining.startIndex, offsetBy: characterBudget)
            let split = preferredSplit(in: remaining, through: limit) ?? limit
            fragments.append(String(remaining[..<split]))
            remaining = String(remaining[split...])
        }

        return fragments
    }

    private static func preferredSplit(in text: String, through limit: String.Index) -> String.Index? {
        var paragraphBreak: String.Index?
        var lineBreak: String.Index?
        var wordBreak: String.Index?
        var previousWasNewline = false

        for index in text.indices {
            guard index <= limit else { break }
            let character = text[index]

            if index > text.startIndex, character.isWhitespace {
                wordBreak = index
                if character == "\n" {
                    lineBreak = index
                    if previousWasNewline {
                        paragraphBreak = text.index(before: index)
                    }
                }
            }

            previousWasNewline = character == "\n"
        }

        for split in [paragraphBreak, lineBreak, wordBreak] {
            if let split, split > text.startIndex {
                return split
            }
        }

        return nil
    }
}
