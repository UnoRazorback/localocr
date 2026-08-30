import Foundation
import LocalOCRModelCore

actor GroundedDocumentIntelligenceProvider: DocumentIntelligenceProviding {
    private static let summaryTask = "Summarize the OCR text as discrete factual statements."
    private static let organizationTask = "Suggest a concise title, category, and tags for the OCR text."
    private static let groundingRequirement = "Return only the requested source-grounded structured result. Every factual value must include its one-based source page and an exact evidence quote. Use nil when an extraction is absent or unsupported."
    private static let maximumSummaryItems = 12
    private static let maximumOrganizationTags = 5

    let availabilityCheck: @Sendable () async -> IntelligenceAvailability
    let provenance: LocalModelProvenance
    let sessionDriver: any StructuredIntelligenceSessionDriving

    init(
        availability: @escaping @Sendable () async -> IntelligenceAvailability,
        provenance: LocalModelProvenance,
        sessionDriver: any StructuredIntelligenceSessionDriving
    ) {
        self.availabilityCheck = availability
        self.provenance = provenance
        self.sessionDriver = sessionDriver
    }

    var availability: IntelligenceAvailability {
        get async { await availabilityCheck() }
    }

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        do {
            try await requireAvailable(document)
            var items: [GeneratedSummaryItem] = []

            summaryChunks: for chunk in try chunks(for: document, task: Self.summaryTask) {
                let responses = try await responses(
                    for: chunk,
                    task: Self.summaryTask
                ) { prompt in
                    try await sessionDriver.summarize(prompt: prompt)
                }
                for response in responses {
                    for item in response.items {
                        guard isGrounded(page: item.page, evidence: item.evidence, in: document) else {
                            continue
                        }
                        items.append(item)
                        if items.count == Self.maximumSummaryItems {
                            break summaryChunks
                        }
                    }
                }
            }

            guard !items.isEmpty else {
                throw IntelligenceError.ungroundedOutput
            }

            let value = IntelligenceSummary(
                text: items.map(\.text).joined(separator: "\n\n"),
                citations: uniqueCitations(
                    items.map { IntelligenceCitation(page: $0.page, quote: $0.evidence) }
                )
            )
            try Task.checkCancellation()
            return ProvenancedIntelligenceResult(value: value, model: provenance)
        } catch is CancellationError {
            throw IntelligenceError.cancelled
        }
    }

    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        do {
            try await requireAvailable(document)
            var title: String?
            var category: String?
            var tags: [String] = []
            var citations: [IntelligenceCitation] = []

            for chunk in try chunks(for: document, task: Self.organizationTask) {
                let responses = try await responses(
                    for: chunk,
                    task: Self.organizationTask
                ) { prompt in
                    try await sessionDriver.organize(prompt: prompt)
                }
                for response in responses {
                    if title == nil, let grounded = grounded(response.title, in: document) {
                        title = grounded.value
                        appendUnique(grounded.citation, to: &citations)
                    }
                    if category == nil, let grounded = grounded(response.category, in: document) {
                        category = grounded.value
                        appendUnique(grounded.citation, to: &citations)
                    }
                    for tag in response.tags {
                        guard tags.count < Self.maximumOrganizationTags else { break }
                        guard let grounded = grounded(tag, in: document) else { continue }
                        if !tags.contains(grounded.value) {
                            tags.append(grounded.value)
                            appendUnique(grounded.citation, to: &citations)
                        }
                    }
                }
            }

            guard title != nil || category != nil || !tags.isEmpty else {
                throw IntelligenceError.ungroundedOutput
            }

            let value = OrganizationSuggestion(
                title: title ?? "",
                category: category ?? "",
                tags: tags,
                citations: citations
            )
            try Task.checkCancellation()
            return ProvenancedIntelligenceResult(value: value, model: provenance)
        } catch is CancellationError {
            throw IntelligenceError.cancelled
        }
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        do {
            try await requireAvailable(document)
            let requestedNames = try normalizedFieldNames(names)

            var groundedByName: [String: ExtractedDocumentField] = [:]
            let requestedFields = requestedNames.enumerated().map { index, name in
                "\(index + 1). \(name)"
            }.joined(separator: "\n")
            let extractionTask = """
                Extract only these requested field names, preserving each name exactly:
                Requested field names:
                \(requestedFields)
                """
            for chunk in try chunks(for: document, task: extractionTask) {
                let responses = try await responses(
                    for: chunk,
                    task: extractionTask
                ) { prompt in
                    try await sessionDriver.extract(names: requestedNames, prompt: prompt)
                }
                for response in responses {
                    let candidates = response.fields.map {
                        ExtractedDocumentField(
                            name: $0.name,
                            value: $0.value,
                            sourcePage: $0.page,
                            evidence: $0.evidence
                        )
                    }
                    for field in IntelligenceGroundingValidator.validExtractedFields(
                        candidates,
                        in: document
                    ) {
                        guard
                            requestedNames.contains(field.name),
                            field.value != nil,
                            groundedByName[field.name] == nil
                        else { continue }
                        groundedByName[field.name] = field
                    }
                }
            }

            let value = requestedNames.map { name in
                groundedByName[name] ?? ExtractedDocumentField(
                    name: name,
                    value: nil,
                    sourcePage: nil,
                    evidence: nil
                )
            }
            try Task.checkCancellation()
            return ProvenancedIntelligenceResult(value: value, model: provenance)
        } catch is CancellationError {
            throw IntelligenceError.cancelled
        }
    }

    private func normalizedFieldNames(_ names: [String]) throws -> [String] {
        guard !names.isEmpty else {
            throw IntelligenceError.invalidFields
        }

        var seen: Set<String> = []
        var normalized: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw IntelligenceError.invalidFields
            }
            if seen.insert(trimmed).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
    }

    private func requireAvailable(_ document: IntelligenceDocument) async throws {
        try Task.checkCancellation()
        let currentAvailability = await availabilityCheck()
        guard currentAvailability == .available else {
            throw IntelligenceError.unavailable(currentAvailability)
        }
        guard !document.pages.isEmpty else {
            throw IntelligenceError.emptyDocument
        }
    }

    private func chunks(
        for document: IntelligenceDocument,
        task: String
    ) throws -> [IntelligenceChunk] {
        try document.pages.flatMap { page in
            let sourceBudget = try sourceCharacterBudget(page: page.number, task: task)
            return try IntelligenceChunker.validatedChunks(
                document: IntelligenceDocument(pages: [page]),
                characterBudget: sourceBudget
            )
        }
    }

    private func responses<Response: Sendable>(
        for chunk: IntelligenceChunk,
        task: String,
        drive: (String) async throws -> Response
    ) async throws -> [Response] {
        do {
            try Task.checkCancellation()
            let response = try await drive(try prompt(for: chunk, task: task))
            try Task.checkCancellation()
            return [response]
        } catch IntelligenceError.contextOverflow {
            var retried: [Response] = []
            let sourceBudget = try sourceCharacterBudget(page: chunk.page, task: task)
            for splitChunk in try FoundationModelsBudget.retryChunks(
                chunk,
                sourceCharacterBudget: sourceBudget
            ) {
                try Task.checkCancellation()
                let response = try await drive(try prompt(for: splitChunk, task: task))
                try Task.checkCancellation()
                retried.append(response)
            }
            return retried
        }
    }

    private func sourceCharacterBudget(page: Int, task: String) throws -> Int {
        let fixedPrompt = IntelligencePromptBuilder.documentPrompt(
            task: """
                \(task)
                \(Self.groundingRequirement)
                """,
            pages: [IntelligenceSourcePage(number: page, text: "")]
        )
        return try FoundationModelsBudget.sourceCharacterBudget(
            completePromptCharacterBudget: FoundationModelsBudget.characterBudget(
                contextSize: sessionDriver.contextSize
            ),
            fixedPromptCharacterCount: fixedPrompt.count
        )
    }

    private func prompt(for chunk: IntelligenceChunk, task: String) throws -> String {
        let prompt = IntelligencePromptBuilder.documentPrompt(
            task: """
                \(task)
                \(Self.groundingRequirement)
                """,
            pages: [IntelligenceSourcePage(number: chunk.page, text: chunk.text)]
        )
        guard prompt.count <= FoundationModelsBudget.characterBudget(
            contextSize: sessionDriver.contextSize
        ) else {
            throw IntelligenceError.contextOverflow
        }
        return prompt
    }

    private func isGrounded(
        page: Int,
        evidence: String,
        in document: IntelligenceDocument
    ) -> Bool {
        !IntelligenceGroundingValidator.validCitations(
            [IntelligenceCitation(page: page, quote: evidence)],
            in: document
        ).isEmpty
    }

    private func grounded(
        _ fact: GeneratedFact?,
        in document: IntelligenceDocument
    ) -> (value: String, citation: IntelligenceCitation)? {
        guard let fact, isGrounded(page: fact.page, evidence: fact.evidence, in: document) else {
            return nil
        }
        return (fact.value, IntelligenceCitation(page: fact.page, quote: fact.evidence))
    }

    private func uniqueCitations(
        _ citations: [IntelligenceCitation]
    ) -> [IntelligenceCitation] {
        citations.reduce(into: []) { result, citation in
            appendUnique(citation, to: &result)
        }
    }

    private func appendUnique(
        _ citation: IntelligenceCitation,
        to citations: inout [IntelligenceCitation]
    ) {
        if !citations.contains(citation) {
            citations.append(citation)
        }
    }
}
