import CryptoKit
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

    private struct QualificationCacheEntry: Codable, Sendable {
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
    private let fixture: LocalModelQualificationFixture
    private let cacheDirectory: URL?
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
        fixture = try! Self.loadFixture()
    }

    init(
        providerFactory: @escaping ProviderFactory,
        now: @escaping @Sendable () -> Date,
        fixture: LocalModelQualificationFixture,
        cacheDirectory: URL? = nil
    ) {
        self.providerFactory = providerFactory
        self.now = now
        self.fixture = fixture
        self.cacheDirectory = cacheDirectory
    }

    public func qualify(
        _ identity: LocalModelIdentity
    ) async throws -> LocalModelQualificationOutcome {
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
        outcomes[key] = outcome
        outcomeIdentities[key] = identity
        try await persist(outcome, identity: identity)
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
            return outcome.status == .failed && outcomeIdentities[key] == identity
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
        guard let url = Bundle.module.url(
            forResource: "local-model-qualification-v1",
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(
            forResource: "local-model-qualification-v1",
            withExtension: "json"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let payload = try JSONDecoder().decode(FixturePayload.self, from: Data(contentsOf: url))
        return LocalModelQualificationFixture(
            version: payload.fixtureVersion,
            document: IntelligenceDocument(pages: payload.pages),
            fields: payload.fields
        )
    }

    private func persist(
        _ outcome: LocalModelQualificationOutcome,
        identity: LocalModelIdentity
    ) async throws {
        guard let store = cacheStore(for: identity) else { return }
        try await store.replace(with: QualificationCacheEntry(
            schemaVersion: QualificationCacheEntry.currentSchemaVersion,
            identity: identity,
            status: outcome.status,
            receipt: outcome.receipt,
            failures: outcome.failures
        ))
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
            )
        )
    }

    private nonisolated static func validSummary(
        _ summary: IntelligenceSummary,
        in document: IntelligenceDocument
    ) -> Bool {
        !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !summary.citations.isEmpty &&
            IntelligenceGroundingValidator.validCitations(summary.citations, in: document) == summary.citations
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
