import CryptoKit
import Darwin
import Foundation
import LocalOCRModelCore

public enum LocalModelQualificationStatus: String, Codable, Sendable, Equatable {
    case untested
    case passed
    case failed
    case stale
}

public struct LocalModelQualificationOutcome: Sendable, Equatable {
    public let status: LocalModelQualificationStatus
    public let receipt: LocalModelQualificationReceipt?
    public let failures: [String]

    public init(
        status: LocalModelQualificationStatus,
        receipt: LocalModelQualificationReceipt?,
        failures: [String]
    ) {
        self.status = status
        self.receipt = receipt
        self.failures = failures
    }
}

struct LocalModelQualificationFixture: Sendable, Equatable {
    let version: Int
    let document: IntelligenceDocument
    let fields: [String]
}

public actor LocalModelQualificationService {
    public typealias ProviderFactory = @Sendable (
        LocalModelIdentity
    ) async throws -> any DocumentIntelligenceProviding

    private struct ModelKey: Hashable {
        let provider: LocalModelProviderID
        let model: String
    }

    private enum SummaryDomain: Hashable {
        case invoice
        case project

        var page: Int {
            switch self {
            case .invoice: 1
            case .project: 2
            }
        }
    }

    private struct QualificationCacheEntry: Codable, Sendable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let identity: LocalModelIdentity
        let status: LocalModelQualificationStatus
        let receipt: LocalModelQualificationReceipt?
        let failures: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case identity
            case status
            case receipt
            case failures
        }
    }

    private struct FixturePayload: Decodable {
        let fixtureVersion: Int
        let pages: [IntelligenceSourcePage]
        let fields: [String]

        enum CodingKeys: String, CodingKey {
            case fixtureVersion = "fixture_version"
            case pages
            case fields
        }
    }

    private let providerFactory: ProviderFactory
    private let now: @Sendable () -> Date
    private let fixture: LocalModelQualificationFixture?
    private let cacheDirectory: URL?
    private let expectedCacheOwnerID: uid_t
    private let cacheStoreHooks: SecureJSONReceiptStoreHooks
    private var outcomes: [ModelKey: LocalModelQualificationOutcome] = [:]
    private var outcomeIdentities: [ModelKey: LocalModelIdentity] = [:]

    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/com.rayconsulting.localocr",
                directoryHint: .isDirectory
            )
    }

    public init(
        providerFactory: @escaping ProviderFactory,
        now: @escaping @Sendable () -> Date = Date.init,
        cacheDirectory: URL? = LocalModelQualificationService.defaultCacheDirectory
    ) {
        self.providerFactory = providerFactory
        self.now = now
        self.cacheDirectory = cacheDirectory
        expectedCacheOwnerID = geteuid()
        cacheStoreHooks = SecureJSONReceiptStoreHooks()
        fixture = try? Self.loadFixture()
    }

    init(
        providerFactory: @escaping ProviderFactory,
        now: @escaping @Sendable () -> Date,
        fixture: LocalModelQualificationFixture,
        cacheDirectory: URL? = nil
    ) {
        self.providerFactory = providerFactory
        self.now = now
        self.fixture = Self.isCanonicalFixture(fixture) ? fixture : nil
        self.cacheDirectory = cacheDirectory
        expectedCacheOwnerID = geteuid()
        cacheStoreHooks = SecureJSONReceiptStoreHooks()
    }

    init(
        providerFactory: @escaping ProviderFactory,
        now: @escaping @Sendable () -> Date,
        cacheDirectory: URL?,
        expectedCacheOwnerID: uid_t,
        cacheStoreHooks: SecureJSONReceiptStoreHooks = SecureJSONReceiptStoreHooks()
    ) {
        self.providerFactory = providerFactory
        self.now = now
        self.cacheDirectory = cacheDirectory
        self.expectedCacheOwnerID = expectedCacheOwnerID
        self.cacheStoreHooks = cacheStoreHooks
        fixture = try? Self.loadFixture()
    }

    init(
        providerFactory: @escaping ProviderFactory,
        now: @escaping @Sendable () -> Date,
        cacheDirectory: URL?,
        fixtureLoader: @escaping @Sendable () throws -> LocalModelQualificationFixture
    ) {
        self.providerFactory = providerFactory
        self.now = now
        self.cacheDirectory = cacheDirectory
        expectedCacheOwnerID = geteuid()
        cacheStoreHooks = SecureJSONReceiptStoreHooks()
        if let loaded = try? fixtureLoader(), Self.isCanonicalFixture(loaded) {
            fixture = loaded
        } else {
            fixture = nil
        }
    }

    public func qualify(
        _ identity: LocalModelIdentity
    ) async throws -> LocalModelQualificationOutcome {
        guard let fixture else {
            throw IntelligenceError.bridgeInvalid
        }
        guard identity.provider != .appleFoundationModels,
              Self.hasExactExternalIdentity(identity)
        else {
            throw IntelligenceError.selection(.qualificationRequired(identity))
        }

        let provider = try await providerFactory(identity)
        var passedActions: Set<LocalIntelligenceAction> = []
        var failures: [String] = []

        do {
            let result = try await provider.summarize(fixture.document)
            if Self.validSummary(result.value, in: fixture.document),
               Self.provenance(result.model, matches: identity) {
                passedActions.insert(.summary)
            } else {
                failures.append(LocalIntelligenceAction.summary.rawValue)
            }
        } catch {
            failures.append(LocalIntelligenceAction.summary.rawValue)
        }

        do {
            let result = try await provider.organize(fixture.document)
            if Self.validOrganization(result.value, in: fixture.document),
               Self.provenance(result.model, matches: identity) {
                passedActions.insert(.organization)
            } else {
                failures.append(LocalIntelligenceAction.organization.rawValue)
            }
        } catch {
            failures.append(LocalIntelligenceAction.organization.rawValue)
        }

        do {
            let result = try await provider.extract(fixture.fields, from: fixture.document)
            if Self.validExtraction(
                result.value,
                fields: fixture.fields,
                in: fixture.document
            ), Self.provenance(result.model, matches: identity) {
                passedActions.insert(.extraction)
            } else {
                failures.append(LocalIntelligenceAction.extraction.rawValue)
            }
        } catch {
            failures.append(LocalIntelligenceAction.extraction.rawValue)
        }

        let outcome: LocalModelQualificationOutcome
        if passedActions == Set(LocalIntelligenceAction.allCases) {
            let receipt = LocalModelQualificationReceipt(
                policyVersion: LocalModelQualificationReceipt.currentPolicyVersion,
                fixtureVersion: fixture.version,
                identity: identity,
                passedActions: passedActions,
                qualifiedAt: now()
            )
            outcome = LocalModelQualificationOutcome(
                status: .passed,
                receipt: receipt,
                failures: []
            )
        } else {
            outcome = LocalModelQualificationOutcome(
                status: .failed,
                receipt: nil,
                failures: failures
            )
        }
        let key = ModelKey(provider: identity.provider, model: identity.model)
        try await persist(outcome, identity: identity)
        outcomes[key] = outcome
        outcomeIdentities[key] = identity
        return outcome
    }

    public func cachedOutcome(
        for identity: LocalModelIdentity
    ) async -> LocalModelQualificationOutcome? {
        let key = ModelKey(provider: identity.provider, model: identity.model)
        let outcome: LocalModelQualificationOutcome
        if let cached = outcomes[key] {
            outcome = cached
        } else if let persisted = await persistedOutcome(for: identity) {
            outcomes[key] = persisted
            outcomeIdentities[key] = identity
            outcome = persisted
        } else {
            return nil
        }
        guard let receipt = outcome.receipt else {
            return (outcome.status == .failed && outcomeIdentities[key] == identity) ||
                outcome.status == .stale
                ? outcome
                : LocalModelQualificationOutcome(
                    status: .stale,
                    receipt: nil,
                    failures: ["identity_or_policy_changed"]
                )
        }
        let currentStatus = status(for: identity, receipt: receipt)
        guard currentStatus == .passed else {
            return LocalModelQualificationOutcome(
                status: .stale,
                receipt: nil,
                failures: ["identity_or_policy_changed"]
            )
        }
        return outcome
    }

    nonisolated func status(
        for identity: LocalModelIdentity,
        receipt: LocalModelQualificationReceipt
    ) -> LocalModelQualificationStatus {
        guard receipt.policyVersion == LocalModelQualificationReceipt.currentPolicyVersion,
              receipt.fixtureVersion == LocalModelQualificationReceipt.currentFixtureVersion,
              receipt.identity == identity,
              receipt.passedActions == Set(LocalIntelligenceAction.allCases),
              Self.hasExactExternalIdentity(identity)
        else {
            return .stale
        }
        return .passed
    }

    static func loadFixture() throws -> LocalModelQualificationFixture {
        let data = try JSONSerialization.data(
            withJSONObject: canonicalFixtureJSONObject(),
            options: [.sortedKeys]
        )
        return try decodeFixture(data)
    }

    static func decodeFixture(_ data: Data) throws -> LocalModelQualificationFixture {
        let object = try JSONSerialization.jsonObject(with: data)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: canonicalFixtureJSONObject(),
            options: [.sortedKeys]
        )
        let normalizedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard normalizedData == canonicalData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let payload = try JSONDecoder().decode(FixturePayload.self, from: data)
        let fixture = LocalModelQualificationFixture(
            version: payload.fixtureVersion,
            document: IntelligenceDocument(pages: payload.pages),
            fields: payload.fields
        )
        guard Self.isCanonicalFixture(fixture) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return fixture
    }

    private nonisolated static let canonicalFixture = LocalModelQualificationFixture(
        version: 1,
        document: IntelligenceDocument(pages: [
            .init(number: 1, text: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
            .init(number: 2, text: "Project: LocalOCR Qualification. Status: synthetic test only.")
        ]),
        fields: ["date", "total", "reference_number"]
    )

    private nonisolated static func canonicalFixtureJSONObject() -> [String: Any] {
        [
            "fixture_version": 1,
            "pages": [
                ["number": 1, "text": "Invoice Q-104. Date: 2026-08-29. Total: $144.17."],
                ["number": 2, "text": "Project: LocalOCR Qualification. Status: synthetic test only."]
            ],
            "fields": ["date", "total", "reference_number"]
        ]
    }

    private nonisolated static func isCanonicalFixture(
        _ fixture: LocalModelQualificationFixture
    ) -> Bool {
        fixture == canonicalFixture
    }

    private func persist(
        _ outcome: LocalModelQualificationOutcome,
        identity: LocalModelIdentity
    ) async throws {
        guard let store = cacheStore(for: identity) else { return }
        let entry = QualificationCacheEntry(
            schemaVersion: QualificationCacheEntry.currentSchemaVersion,
            identity: identity,
            status: outcome.status,
            receipt: outcome.receipt,
            failures: outcome.failures
        )
        try await store.replace(with: entry)
    }

    private func persistedOutcome(
        for identity: LocalModelIdentity
    ) async -> LocalModelQualificationOutcome? {
        guard let store = cacheStore(for: identity) else { return nil }
        do {
            let entry = try await store.read()
            guard entry.schemaVersion == QualificationCacheEntry.currentSchemaVersion else {
                return LocalModelQualificationOutcome(
                    status: .stale,
                    receipt: nil,
                    failures: ["qualification_cache_invalid"]
                )
            }
            if entry.identity != identity {
                return LocalModelQualificationOutcome(
                    status: .stale,
                    receipt: nil,
                    failures: ["identity_or_policy_changed"]
                )
            }
            if let receipt = entry.receipt,
               status(for: identity, receipt: receipt) != .passed {
                return LocalModelQualificationOutcome(
                    status: .stale,
                    receipt: nil,
                    failures: ["identity_or_policy_changed"]
                )
            }
            return LocalModelQualificationOutcome(
                status: entry.status,
                receipt: entry.receipt,
                failures: entry.failures
            )
        } catch SecureJSONReceiptStoreError.missingPath {
            return nil
        } catch {
            return LocalModelQualificationOutcome(
                status: .stale,
                receipt: nil,
                failures: ["qualification_cache_invalid"]
            )
        }
    }

    private func cacheStore(
        for identity: LocalModelIdentity
    ) -> SecureJSONReceiptStore<QualificationCacheEntry>? {
        guard let cacheDirectory else { return nil }
        let key = "\(identity.provider.rawValue)\u{0}\(identity.model)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = cacheDirectory.appending(
            path: "local-intelligence-qualification-\(identity.provider.rawValue)-\(digest).json",
            directoryHint: .notDirectory
        )
        let identitySchema = SecureJSONReceiptSchema.object(
            required: ["provider": .value, "model": .value],
            optional: ["fingerprint": .value, "harnessVersion": .value]
        )
        let receiptSchema = SecureJSONReceiptSchema.object(required: [
            "policy_version": .value,
            "fixture_version": .value,
            "identity": identitySchema,
            "passed_actions": .array(.value),
            "qualified_at": .value
        ])
        return SecureJSONReceiptStore(
            receiptURL: url,
            expectedReceiptOwnerID: expectedCacheOwnerID,
            allowedTopLevelMemberSets: [
                ["schema_version", "identity", "status", "receipt", "failures"],
                ["schema_version", "identity", "status", "failures"]
            ],
            receiptSchema: .object(
                required: [
                    "schema_version": .value,
                    "identity": identitySchema,
                    "status": .value,
                    "failures": .array(.value)
                ],
                optional: ["receipt": receiptSchema]
            ),
            receiptsEquivalent: ==,
            hooks: cacheStoreHooks
        )
    }

    private nonisolated static func validSummary(
        _ summary: IntelligenceSummary,
        in document: IntelligenceDocument
    ) -> Bool {
        guard !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.citations.isEmpty,
              IntelligenceGroundingValidator.validCitations(
                  summary.citations,
                  in: document
              ) == summary.citations
        else {
            return false
        }
        let citationDomains = summary.citations.compactMap {
            canonicalSummaryDomain(for: $0, in: document)
        }
        guard citationDomains.count == summary.citations.count else {
            return false
        }
        let items = summaryItems(in: summary.text)
        guard !items.isEmpty else {
            return false
        }
        let itemDomains = items.compactMap { item -> SummaryDomain? in
            let clauses = summaryClauses(in: item)
            guard !clauses.isEmpty else { return nil }
            let domains = clauses.compactMap(summaryClauseDomain)
            guard domains.count == clauses.count,
                  Set(domains).count == 1
            else {
                return nil
            }
            return domains[0]
        }
        guard itemDomains.count == items.count else { return false }
        let citedDomains = Set(citationDomains)
        return itemDomains.allSatisfy(citedDomains.contains)
    }

    private nonisolated static func canonicalSummaryDomain(
        for citation: IntelligenceCitation,
        in document: IntelligenceDocument
    ) -> SummaryDomain? {
        guard let page = document.pages.first(where: { $0.number == citation.page }),
              citation.quote == page.text
        else {
            return nil
        }
        switch citation.page {
        case SummaryDomain.invoice.page: return .invoice
        case SummaryDomain.project.page: return .project
        default: return nil
        }
    }

    private nonisolated static func summaryClauseDomain(
        _ clause: String
    ) -> SummaryDomain? {
        let tokens = summaryTokens(in: clause)
        guard !tokens.isEmpty,
              !tokens.contains("or"),
              validColonConnectors(in: clause)
        else {
            return nil
        }
        let clauseGlue: Set<String> = ["a", "an", "and", "has", "is", "the", "with"]
        guard validSummaryClauseEdges(tokens, clauseGlue: clauseGlue)
        else {
            return nil
        }
        let tokenSet = Set(tokens)
        let invoiceIndicators: Set<String> = [
            "invoice", "reference", "number", "q", "104", "date", "dated", "datetime",
            "total", "totals", "amount", "value",
            "2026", "08", "29", "144", "17"
        ]
        let projectIndicators: Set<String> = [
            "project", "localocr", "qualification", "status", "synthetic", "test", "only"
        ]
        let hasInvoiceFacts = !tokenSet.isDisjoint(with: invoiceIndicators)
        let hasProjectFacts = !tokenSet.isDisjoint(with: projectIndicators)
        guard hasInvoiceFacts != hasProjectFacts else { return nil }

        if hasInvoiceFacts {
            let relations: [[String]] = [
                ["invoice", "q", "104"],
                ["invoice", "reference", "q", "104"],
                ["invoice", "number", "q", "104"],
                ["on", "2026", "08", "29"],
                ["date", "2026", "08", "29"],
                ["date", "is", "2026", "08", "29"],
                ["date", "of", "2026", "08", "29"],
                ["dated", "2026", "08", "29"],
                ["datetime", "2026", "08", "29"],
                ["datetime", "is", "2026", "08", "29"]
            ] + ["total", "totals", "amount", "value"].flatMap { label in
                [
                    [label, "144", "17"],
                    [label, "is", "144", "17"],
                    [label, "of", "144", "17"]
                ]
            }
            return everyMaterialTokenIsInACompleteRelation(
                tokens,
                relations: relations,
                clauseGlue: clauseGlue
            ) ? .invoice : nil
        }

        return everyMaterialTokenIsInACompleteRelation(
            tokens,
            relations: [
                ["project", "localocr", "qualification"],
                ["project", "is", "localocr", "qualification"],
                ["localocr", "qualification", "is", "a", "project"],
                ["localocr", "qualification", "is", "the", "project"],
                ["status", "synthetic", "test", "only"],
                ["status", "is", "synthetic", "test", "only"]
            ],
            clauseGlue: clauseGlue
        ) ? .project : nil
    }

    private nonisolated static func validSummaryClauseEdges(
        _ tokens: [String],
        clauseGlue: Set<String>
    ) -> Bool {
        let articles: Set<String> = ["a", "an", "the"]
        let forbiddenEdgeGlue = clauseGlue
            .union(["or", "but", "plus"])
            .subtracting(articles)
        guard let firstMaterial = tokens.drop(while: articles.contains).first,
              !forbiddenEdgeGlue.contains(firstMaterial),
              let lastToken = tokens.last,
              !articles.contains(lastToken),
              let lastMaterial = tokens.reversed().drop(while: articles.contains).first,
              !forbiddenEdgeGlue.contains(lastMaterial)
        else {
            return false
        }
        return true
    }

    private nonisolated static func summaryItems(in value: String) -> [String] {
        var normalized = ""
        var previousWasCarriageReturn = false
        for scalar in value.unicodeScalars {
            if scalar == "\r" {
                normalized.append("\n")
                previousWasCarriageReturn = true
            } else if scalar == "\n" {
                if !previousWasCarriageReturn { normalized.append("\n") }
                previousWasCarriageReturn = false
            } else if CharacterSet.newlines.contains(scalar) {
                normalized.append("\n")
                previousWasCarriageReturn = false
            } else {
                normalized.unicodeScalars.append(scalar)
                previousWasCarriageReturn = false
            }
        }
        var items: [String] = []
        var lines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                let item = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { items.append(item) }
                lines.removeAll(keepingCapacity: true)
            } else {
                lines.append(trimmed)
            }
        }
        let item = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !item.isEmpty { items.append(item) }
        return items
    }

    private nonisolated static func summaryClauses(in value: String) -> [String] {
        let scalars = Array(value.lowercased().unicodeScalars)
        var clauses: [String] = []
        var current = ""
        func flush() {
            let clause = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clause.isEmpty { clauses.append(clause) }
            current = ""
        }
        for index in scalars.indices {
            let scalar = scalars[index]
            let previous = index > scalars.startIndex ? scalars[scalars.index(before: index)] : nil
            let next = index < scalars.index(before: scalars.endIndex)
                ? scalars[scalars.index(after: index)]
                : nil
            let decimalPoint = scalar == "." && previous?.properties.numericType != nil &&
                next?.properties.numericType != nil
            let relationHyphen = scalar == "-" && (
                (previous?.properties.numericType != nil && next?.properties.numericType != nil) ||
                (previous == "q" && next?.properties.numericType != nil)
            )
            let attachedCurrency = scalar == "$" && next?.properties.numericType != nil
            let ordinaryWhitespace = scalar == " " || scalar == "\t" ||
                scalar.properties.generalCategory == .spaceSeparator
            if CharacterSet.newlines.contains(scalar) {
                flush()
            } else if scalar == ":" {
                current.append(":")
            } else if decimalPoint || relationHyphen || attachedCurrency ||
                CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if ordinaryWhitespace {
                current.append(" ")
            } else {
                flush()
            }
        }
        flush()
        return clauses
    }

    private nonisolated static func validColonConnectors(in clause: String) -> Bool {
        let segments = clause.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count > 1 else { return true }
        let expectedValueStart: [String: String] = [
            "invoice": "q",
            "reference": "q",
            "number": "q",
            "date": "2026",
            "datetime": "2026",
            "total": "144",
            "totals": "144",
            "amount": "144",
            "value": "144",
            "project": "localocr",
            "status": "synthetic"
        ]
        for index in 0..<(segments.count - 1) {
            let labels = summaryTokens(in: String(segments[index]))
            let values = summaryTokens(in: String(segments[index + 1]))
            guard let label = labels.last,
                  let value = values.first,
                  expectedValueStart[label] == value
            else {
                return false
            }
        }
        return true
    }

    private nonisolated static func summaryTokens(in value: String) -> [String] {
        return value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private nonisolated static func everyMaterialTokenIsInACompleteRelation(
        _ tokens: [String],
        relations: [[String]],
        clauseGlue: Set<String>
    ) -> Bool {
        let covered = relations.reduce(into: Set<Int>()) { covered, relation in
            for match in relationMatches(relation, in: tokens) {
                covered.formUnion(match.indices)
            }
        }
        guard !covered.isEmpty else { return false }
        return tokens.indices.allSatisfy { covered.contains($0) || clauseGlue.contains(tokens[$0]) }
    }

    private nonisolated static func relationMatches(
        _ material: [String],
        in tokens: [String]
    ) -> [ArraySlice<String>] {
        guard !material.isEmpty, material.count <= tokens.count else { return [] }
        return tokens.indices.compactMap { start in
            let end = start + material.count
            guard end <= tokens.endIndex else { return nil }
            let candidate = tokens[start..<end]
            return Array(candidate) == material ? candidate : nil
        }
    }

    private nonisolated static func validOrganization(
        _ organization: OrganizationSuggestion,
        in document: IntelligenceDocument
    ) -> Bool {
        let title = organization.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = organization.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !category.isEmpty,
              organization.tags.count <= 5,
              IntelligenceGroundingValidator.validCitations(
                  organization.citations,
                  in: document
              ) == organization.citations
        else {
            return false
        }
        return organization.citations.contains { normalized($0.quote).contains(normalized(title)) } &&
            organization.citations.contains { normalized($0.quote).contains(normalized(category)) } &&
            organization.tags.allSatisfy { tag in
                let normalizedTag = normalized(tag.trimmingCharacters(in: .whitespacesAndNewlines))
                return !normalizedTag.isEmpty && organization.citations.contains {
                    normalized($0.quote).contains(normalizedTag)
                }
            }
    }

    private nonisolated static func validExtraction(
        _ extraction: [ExtractedDocumentField],
        fields: [String],
        in document: IntelligenceDocument
    ) -> Bool {
        guard extraction.map(\.name) == fields,
              IntelligenceGroundingValidator.validExtractedFields(extraction, in: document) == extraction
        else {
            return false
        }
        let expected: [String: String] = [
            "date": "2026-08-29",
            "total": "$144.17",
            "reference_number": "Q-104"
        ]
        return extraction.allSatisfy { field in
            field.value == expected[field.name] &&
                field.sourcePage == 1 &&
                !(field.evidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private nonisolated static func provenance(
        _ provenance: LocalModelProvenance,
        matches identity: LocalModelIdentity
    ) -> Bool {
        provenance.provider == identity.provider &&
            provenance.model == identity.model &&
            provenance.fingerprint == identity.fingerprint &&
            provenance.processing == .onDeviceLoopback
    }

    private nonisolated static func hasExactExternalIdentity(
        _ identity: LocalModelIdentity
    ) -> Bool {
        !identity.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !(identity.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            !(identity.harnessVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
