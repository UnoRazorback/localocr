import Darwin
import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalModelQualificationServiceTests {
    @Test func qualificationRequiresAllThreeActionsAndCachesNoReceiptForAPartialPass() async throws {
        let provider = Task6FixtureProvider(extraction: [
            .init(name: "date", value: "2026-08-29", sourcePage: 1, evidence: "Date: 2026-08-29"),
            .init(name: "total", value: "$144.17", sourcePage: 1, evidence: "Total: $144.17"),
            .init(name: "reference_number", value: nil, sourcePage: nil, evidence: nil)
        ])
        let service = task6QualificationService(provider: provider)

        let outcome = try await service.qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["extraction"])
        #expect(await service.cachedOutcome(for: task6OllamaIdentity)?.status == .failed)
    }

    @Test func qualificationPassesOnlyForExactGroundedFactsWithCorrectPageEvidence() async throws {
        let service = task6QualificationService(provider: Task6FixtureProvider())

        let outcome = try await service.qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.receipt?.identity == task6OllamaIdentity)
        #expect(outcome.receipt?.passedActions == Set(LocalIntelligenceAction.allCases))
        #expect(outcome.receipt?.fixtureVersion == 1)
        #expect(outcome.receipt?.policyVersion == 1)
        #expect(outcome.receipt?.qualifiedAt == task6Now)
    }

    @Test func extractionWithWrongPageEvidenceCannotProduceASelectableReceipt() async throws {
        let provider = Task6FixtureProvider(extraction: [
            .init(name: "date", value: "2026-08-29", sourcePage: 2, evidence: "synthetic test only"),
            .init(name: "total", value: "$144.17", sourcePage: 1, evidence: "Total: $144.17"),
            .init(name: "reference_number", value: "Q-104", sourcePage: 1, evidence: "Invoice Q-104")
        ])

        let outcome = try await task6QualificationService(provider: provider).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["extraction"])
    }

    @Test func organizationWithAnUngroundedTagCannotProduceASelectableReceipt() async throws {
        let provider = Task6FixtureProvider(organization: .init(
            title: "Invoice Q-104",
            category: "LocalOCR Qualification",
            tags: ["unsupported remote claim"],
            citations: [
                .init(page: 1, quote: "Invoice Q-104"),
                .init(page: 2, quote: "LocalOCR Qualification")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["organization"])
    }

    @Test func summaryWithUnsupportedClaimAndUnrelatedValidQuoteFailsQualification() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice Q-104 totals $144.17 and was paid through a cloud payment service.",
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.receipt == nil)
        #expect(outcome.failures == ["summary"])
    }

    @Test func summaryRejectsFalseCrossPageRelationshipUsingOnlyFixtureVocabulary() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Project Q-104 totals $144.17.",
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
                .init(page: 2, quote: "Project: LocalOCR Qualification. Status: synthetic test only.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test func summaryRejectsRecombinedPageFactsThatReverseTheirRelations() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice $144.17 and total Q-104.",
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test(arguments: [
        "Invoice. Q-104.",
        "Invoice reference Q-104 or total $144.17.",
        "Invoice reference Q-104 has total $144.17. Cloud payment accepted."
    ])
    func everyInvoiceClauseMustAssertACompleteUnambiguousRelation(
        text: String
    ) async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: text,
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test func separatedProjectNameAndTypeFragmentsFailQualification() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "LocalOCR Qualification. Project.",
            citations: [
                .init(page: 2, quote: "Project: LocalOCR Qualification. Status: synthetic test only.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test(arguments: [
        "Invoice: Q-104",
        "Invoice reference Q-104 has total $144.17.",
        "Invoice number Q-104 has amount $144.17 and is dated 2026-08-29.",
        "Invoice number Q-104 has value $144.17 and is dated 2026-08-29."
    ])
    func explicitInvoiceRelationParaphrasesPassQualification(
        text: String
    ) async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: text,
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func trivialSummaryWithoutACompleteFixtureRelationFailsQualification() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice",
            citations: [.init(page: 1, quote: "Invoice Q-104")]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test func groundedInvoiceAndProjectParaphrasesPassQualification() async throws {
        let summaries = [
            IntelligenceSummary(
                text: "Invoice Q-104 has a value of $144.17, dated 2026-08-29.",
                citations: [
                    .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
                ]
            ),
            IntelligenceSummary(
                text: "LocalOCR Qualification is a project with status synthetic test only.",
                citations: [
                    .init(page: 2, quote: "Project: LocalOCR Qualification. Status: synthetic test only.")
                ]
            )
        ]

        for summary in summaries {
            let outcome = try await task6QualificationService(
                provider: Task6FixtureProvider(summary: summary)
            ).qualify(task6OllamaIdentity)
            #expect(outcome.status == .passed)
            #expect(outcome.failures.isEmpty)
        }
    }

    @Test func eachSummaryItemUsesOnlyItsOwnPageEvidence() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice reference Q-104 has total $144.17.\n\nThe project is LocalOCR Qualification and the status is synthetic test only.",
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
                .init(page: 2, quote: "Project: LocalOCR Qualification. Status: synthetic test only.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func summaryItemsUseGlobalCanonicalProvenanceWithoutPositionalCitationPairing() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice reference Q-104 has total $144.17.\n\nThe project is LocalOCR Qualification and the status is synthetic test only.",
            citations: [
                .init(page: 2, quote: "Project: LocalOCR Qualification. Status: synthetic test only."),
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func multipleSamePageSummaryItemsMayShareOneDeduplicatedCanonicalCitation() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice reference Q-104.\n\nInvoice Q-104 has total $144.17.",
            citations: [
                .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
            ]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func groundedProviderDeduplicatedSummaryCitationPassesQualification() async throws {
        let provider = GroundedDocumentIntelligenceProvider(
            availability: { .available },
            provenance: task6Provenance(),
            sessionDriver: Task6QualificationGroundedDriver()
        )

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.receipt?.passedActions == Set(LocalIntelligenceAction.allCases))
    }

    @Test func partialFixtureQuoteIsNotCanonicalQualificationProvenance() async throws {
        let provider = Task6FixtureProvider(summary: .init(
            text: "Invoice reference Q-104.",
            citations: [.init(page: 1, quote: "Invoice Q-104")]
        ))

        let outcome = try await task6QualificationService(provider: provider)
            .qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test(arguments: [
        "Invoice… Q-104",
        "LocalOCR Qualification — Project",
        "LocalOCR Qualification – Project",
        "Invoice; Q-104",
        "Invoice, Q-104",
        "Invoice? Q-104",
        "Invoice! Q-104",
        "Invoice | Q-104",
        "Invoice + Q-104",
        "Invoice = Q-104",
        "Invoice~Q-104",
        "Invoice / Q-104",
        "Invoice \\ Q-104",
        "Invoice # Q-104",
        "Invoice % Q-104",
        "Invoice & Q-104",
        "Invoice * Q-104",
        "Invoice @ Q-104",
        "Invoice ^ Q-104",
        "Invoice _ Q-104",
        "Invoice ` Q-104",
        "Invoice < Q-104",
        "Invoice > Q-104",
        "Invoice $ Q-104",
        "Invoice-Q-104",
        "Invoice 💥 Q-104",
        "Invoice\u{200B}Q-104",
        "Invoice\nQ-104",
        "Invoice (reference) Q-104",
        "Invoice [number] Q-104",
        "Invoice \"reference\" Q-104"
    ])
    func unicodeAndAsciiClauseBoundariesCannotJoinRelationFragments(
        text: String
    ) async throws {
        let page = text.contains("Invoice") ? 1 : 2
        let quote = page == 1
            ? "Invoice Q-104. Date: 2026-08-29. Total: $144.17."
            : "Project: LocalOCR Qualification. Status: synthetic test only."
        let outcome = try await task6QualificationService(
            provider: Task6FixtureProvider(summary: .init(
                text: text,
                citations: [.init(page: page, quote: quote)]
            ))
        ).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test(arguments: [
        "\"Invoice reference Q-104\"",
        "(Invoice reference Q-104)",
        "Invoice\tQ-104",
        "Invoice Q-104 has total $144.17",
        "Invoice Q-104 has total: $144.17"
    ])
    func approvedWrappersWhitespaceAndRelationPunctuationPassQualification(
        text: String
    ) async throws {
        let outcome = try await task6QualificationService(
            provider: Task6FixtureProvider(summary: .init(
                text: text,
                citations: [
                    .init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")
                ]
            ))
        ).qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test(arguments: [
        "Invoice Q-104 and",
        "and Invoice Q-104",
        "Invoice Q-104 but",
        "with status synthetic test only",
        "status synthetic test only plus",
        "status synthetic test only is",
        "is status synthetic test only",
        "date 2026-08-29 and",
        "date 2026-08-29 has",
        "is dated 2026-08-29",
        "Invoice Q-104 has",
        "has Invoice Q-104",
        "or Invoice Q-104"
    ])
    func danglingOrNonassertiveConnectorsFailQualification(
        text: String
    ) async throws {
        let page = text.localizedCaseInsensitiveContains("invoice") ||
            text.localizedCaseInsensitiveContains("date") ? 1 : 2
        let quote = page == 1
            ? "Invoice Q-104. Date: 2026-08-29. Total: $144.17."
            : "Project: LocalOCR Qualification. Status: synthetic test only."
        let outcome = try await task6QualificationService(
            provider: Task6FixtureProvider(summary: .init(
                text: text,
                citations: [.init(page: page, quote: quote)]
            ))
        ).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test(arguments: [
        "The: project is LocalOCR Qualification",
        "Invoice:: Q-104",
        "Invoice Q-104: has total $144.17",
        "LocalOCR Qualification: is the project"
    ])
    func colonIsAcceptedOnlyAsAnExplicitLabelValueConnector(
        text: String
    ) async throws {
        let page = text.localizedCaseInsensitiveContains("invoice") ? 1 : 2
        let quote = page == 1
            ? "Invoice Q-104. Date: 2026-08-29. Total: $144.17."
            : "Project: LocalOCR Qualification. Status: synthetic test only."
        let outcome = try await task6QualificationService(
            provider: Task6FixtureProvider(summary: .init(
                text: text,
                citations: [.init(page: page, quote: quote)]
            ))
        ).qualify(task6OllamaIdentity)

        #expect(outcome.status == .failed)
        #expect(outcome.failures == ["summary"])
    }

    @Test(arguments: [
        "Invoice Q-104 has datetime 2026-08-29.",
        "The project is LocalOCR Qualification and the status is synthetic test only.",
        "LocalOCR Qualification is the project; the status is synthetic test only."
    ])
    func naturalDateProjectAndStatusRelationsPassQualification(
        text: String
    ) async throws {
        let page = text.localizedCaseInsensitiveContains("invoice") ? 1 : 2
        let quote = page == 1
            ? "Invoice Q-104. Date: 2026-08-29. Total: $144.17."
            : "Project: LocalOCR Qualification. Status: synthetic test only."
        let outcome = try await task6QualificationService(
            provider: Task6FixtureProvider(summary: .init(
                text: text,
                citations: [.init(page: page, quote: quote)]
            ))
        ).qualify(task6OllamaIdentity)

        #expect(outcome.status == .passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func cachedQualificationBecomesStaleForIdentityHarnessFixtureOrPolicyChanges() async throws {
        let service = task6QualificationService(provider: Task6FixtureProvider())
        let passed = try #require(try await service.qualify(task6OllamaIdentity).receipt)
        let changedHarness = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: task6OllamaIdentity.fingerprint,
            harnessVersion: "0.11.9"
        )
        let changedFingerprint = LocalModelIdentity(
            provider: .ollama,
            model: task6OllamaIdentity.model,
            fingerprint: "sha256:changed",
            harnessVersion: task6OllamaIdentity.harnessVersion
        )
        let staleFixture = LocalModelQualificationReceipt(
            policyVersion: 1,
            fixtureVersion: 2,
            identity: task6OllamaIdentity,
            passedActions: Set(LocalIntelligenceAction.allCases),
            qualifiedAt: task6Now
        )
        let stalePolicy = LocalModelQualificationReceipt(
            policyVersion: 2,
            fixtureVersion: 1,
            identity: task6OllamaIdentity,
            passedActions: Set(LocalIntelligenceAction.allCases),
            qualifiedAt: task6Now
        )

        #expect(await service.cachedOutcome(for: changedHarness)?.status == .stale)
        #expect(await service.cachedOutcome(for: changedFingerprint)?.status == .stale)
        #expect(service.status(for: task6OllamaIdentity, receipt: passed) == .passed)
        #expect(service.status(for: task6OllamaIdentity, receipt: staleFixture) == .stale)
        #expect(service.status(for: task6OllamaIdentity, receipt: stalePolicy) == .stale)
    }

    @Test func immutableFixtureContainsOnlyTheApprovedSyntheticFacts() throws {
        let fixture = try LocalModelQualificationService.loadFixture()

        #expect(fixture.version == 1)
        #expect(fixture.document == IntelligenceDocument(pages: [
            .init(number: 1, text: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
            .init(number: 2, text: "Project: LocalOCR Qualification. Status: synthetic test only.")
        ]))
        #expect(fixture.fields == ["date", "total", "reference_number"])
    }

    @Test func passedQualificationCacheSurvivesAServiceRelaunch() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        let first = LocalModelQualificationService(
            providerFactory: { _ in Task6FixtureProvider() },
            now: { task6Now },
            cacheDirectory: fixture.cacheDirectory
        )
        _ = try await first.qualify(task6OllamaIdentity)
        let relaunched = LocalModelQualificationService(
            providerFactory: { _ in
                Issue.record("Reading the cache must not invoke a model")
                return Task6FixtureProvider()
            },
            now: { task6Now },
            cacheDirectory: fixture.cacheDirectory
        )

        let cached = await relaunched.cachedOutcome(for: task6OllamaIdentity)

        #expect(cached?.status == .passed)
        #expect(cached?.receipt == task6QualificationReceipt())
    }

    @Test func corruptQualificationCacheFailsClosedAsStale() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        try await fixture.persistPassedQualification()
        let receiptURL = try fixture.onlyReceiptURL()
        let handle = try FileHandle(forWritingTo: receiptURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"schema_version":1"#.utf8))
        try handle.synchronize()
        try handle.close()

        let cached = await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)

        #expect(cached?.status == .stale)
        #expect(cached?.receipt == nil)
        #expect(cached?.failures == ["qualification_cache_invalid"])
    }

    @Test func insecureCacheOwnerModeSymlinkAndHardLinkAreRejected() async throws {
        do {
            let fixture = try Task6QualificationCacheFixture()
            defer { fixture.remove() }
            try await fixture.persistPassedQualification()
            let receiptURL = try fixture.onlyReceiptURL()
            try #require(chmod(receiptURL.path, 0o644) == 0)
            #expect(await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)?.status == .stale)
        }

        do {
            let fixture = try Task6QualificationCacheFixture()
            defer { fixture.remove() }
            try await fixture.persistPassedQualification()
            let wrongOwner = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
            #expect(await fixture.relaunchedService(
                expectedCacheOwnerID: wrongOwner
            ).cachedOutcome(for: task6OllamaIdentity)?.status == .stale)
        }

        do {
            let fixture = try Task6QualificationCacheFixture()
            defer { fixture.remove() }
            try await fixture.persistPassedQualification()
            let receiptURL = try fixture.onlyReceiptURL()
            let target = fixture.baseURL.appending(path: "symlink-target.json")
            try FileManager.default.moveItem(at: receiptURL, to: target)
            try FileManager.default.createSymbolicLink(at: receiptURL, withDestinationURL: target)
            #expect(await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)?.status == .stale)
        }

        do {
            let fixture = try Task6QualificationCacheFixture()
            defer { fixture.remove() }
            try await fixture.persistPassedQualification()
            let receiptURL = try fixture.onlyReceiptURL()
            try FileManager.default.linkItem(
                at: receiptURL,
                to: fixture.baseURL.appending(path: "qualification-hard-link.json")
            )
            #expect(await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)?.status == .stale)
        }
    }

    @Test func independentConcurrentWritersLeaveOneCompleteReadableOutcome() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        let passed = fixture.relaunchedService(provider: Task6FixtureProvider())
        let failed = fixture.relaunchedService(provider: Task6FixtureProvider(extraction: [
            .init(name: "date", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "total", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "reference_number", value: nil, sourcePage: nil, evidence: nil)
        ]))

        async let passedResult = task6QualificationResult(from: passed)
        async let failedResult = task6QualificationResult(from: failed)
        let writerResults = await [passedResult, failedResult]
        let cached = await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)

        #expect(writerResults.contains { $0 != nil })
        #expect(cached?.status == .passed || cached?.status == .failed)
        #expect(cached?.status != .stale)
    }

    @Test func partialFailureAndOriginalTimestampSurviveIndependentRelaunches() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        let failedService = fixture.relaunchedService(provider: Task6FixtureProvider(extraction: [
            .init(name: "date", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "total", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "reference_number", value: nil, sourcePage: nil, evidence: nil)
        ]))
        _ = try await failedService.qualify(task6OllamaIdentity)

        let failed = await fixture.relaunchedService(now: task6Now.addingTimeInterval(3_600))
            .cachedOutcome(for: task6OllamaIdentity)
        #expect(failed?.status == .failed)
        #expect(failed?.receipt == nil)
        #expect(failed?.failures == ["extraction"])

        try FileManager.default.removeItem(at: try fixture.onlyReceiptURL())
        try await fixture.persistPassedQualification()
        let passed = await fixture.relaunchedService(now: task6Now.addingTimeInterval(86_400))
            .cachedOutcome(for: task6OllamaIdentity)
        #expect(passed?.status == .passed)
        #expect(passed?.receipt?.qualifiedAt == task6Now)
    }

    @Test(arguments: ["missing", "malformed"])
    func missingOrMalformedFixtureResourceFailsClosedWithoutCrashing(_ kind: String) async {
        let service = LocalModelQualificationService(
            providerFactory: { _ in Task6FixtureProvider() },
            now: { task6Now },
            cacheDirectory: nil,
            fixtureLoader: {
                if kind == "missing" { throw CocoaError(.fileNoSuchFile) }
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "malformed fixture"
                ))
            }
        )

        await #expect(throws: IntelligenceError.bridgeInvalid) {
            try await service.qualify(task6OllamaIdentity)
        }
    }

    @Test func syntacticallyValidButSemanticallyAlteredFixtureFailsClosed() async {
        let alteredFixtures = [
            LocalModelQualificationFixture(
                version: 1,
                document: IntelligenceDocument(pages: [
                    .init(number: 1, text: "Invoice Q-104. Date: 2026-08-29. Total: $999.99."),
                    .init(number: 2, text: "Project: LocalOCR Qualification. Status: synthetic test only.")
                ]),
                fields: ["date", "total", "reference_number"]
            ),
            LocalModelQualificationFixture(
                version: 1,
                document: IntelligenceDocument(pages: [
                    .init(number: 1, text: "Invoice Q-104. Date: 2026-08-29. Total: $144.17."),
                    .init(number: 2, text: "Project: LocalOCR Qualification. Status: synthetic test only.")
                ]),
                fields: ["date", "reference_number"]
            )
        ]

        for fixture in alteredFixtures {
            let service = LocalModelQualificationService(
                providerFactory: { _ in Task6FixtureProvider() },
                now: { task6Now },
                cacheDirectory: nil,
                fixtureLoader: { fixture }
            )
            await #expect(throws: IntelligenceError.bridgeInvalid) {
                try await service.qualify(task6OllamaIdentity)
            }
        }
    }

    @Test func decodedFixtureRejectsMissingOrAlteredCanonicalV1FactsAndFields() {
        let fixtures = [
            #"{"fixture_version":1,"pages":[{"number":1,"text":"Invoice Q-104. Date: 2026-08-29. Total: $999.99."},{"number":2,"text":"Project: LocalOCR Qualification. Status: synthetic test only."}],"fields":["date","total","reference_number"]}"#,
            #"{"fixture_version":1,"pages":[{"number":1,"text":"Invoice Q-104. Date: 2026-08-29. Total: $144.17."},{"number":2,"text":"Project: LocalOCR Qualification. Status: synthetic test only."}],"fields":["date","reference_number"]}"#
        ]

        for fixture in fixtures {
            #expect(throws: (any Error).self) {
                try LocalModelQualificationService.decodeFixture(Data(fixture.utf8))
            }
        }
    }

    @Test func concurrentValidWinnerRemainsReadableAndUnquarantinedAfterPeerReturns() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        let first = fixture.relaunchedService(provider: Task6FixtureProvider())
        let second = fixture.relaunchedService(provider: Task6FixtureProvider())

        async let firstResult = task6QualificationResult(from: first)
        async let secondResult = task6QualificationResult(from: second)
        let outcomes = await [firstResult, secondResult]
        let persisted = await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.cacheDirectory,
            includingPropertiesForKeys: nil
        )

        #expect(outcomes.contains { $0?.status == .passed })
        #expect(persisted?.status == .passed)
        #expect(persisted?.receipt == task6QualificationReceipt())
        #expect(entries.count == 1, "unexpected cache entries: \(entries.map(\.lastPathComponent))")
        #expect(entries.allSatisfy { !$0.lastPathComponent.hasSuffix(".quarantine") })
    }

    @Test func preseededCacheSerializesOneHundredDistinctValidReplacementsWithoutArtifacts() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        try await fixture.persistPassedQualification()
        let services = (1...100).map { offset in
            fixture.relaunchedService(
                provider: Task6FixtureProvider(),
                now: task6Now.addingTimeInterval(TimeInterval(offset))
            )
        }

        let outcomes = await withTaskGroup(
            of: LocalModelQualificationOutcome?.self,
            returning: [LocalModelQualificationOutcome?].self
        ) { group in
            for service in services {
                group.addTask { await task6QualificationResult(from: service) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let persisted = await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.cacheDirectory,
            includingPropertiesForKeys: nil
        )

        #expect(outcomes.count == 100)
        #expect(outcomes.allSatisfy { $0?.status == .passed })
        #expect(persisted?.status == .passed)
        #expect(persisted?.receipt?.qualifiedAt != task6Now)
        #expect(entries.count == 1, "unexpected cache entries: \(entries.map(\.lastPathComponent))")
        #expect(entries.allSatisfy {
            !$0.lastPathComponent.hasSuffix(".quarantine") &&
                !$0.lastPathComponent.hasSuffix(".tmp")
        })
    }

    @Test func independentProcessQualificationWriterSerializesWithParentWriter() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        try await fixture.persistPassedQualification()
        let externalLock = try Task6ExternalDirectoryLock(directory: fixture.cacheDirectory)
        defer { externalLock.releaseAndWait() }
        try externalLock.waitUntilLocked()

        let childReady = fixture.baseURL.appending(path: "child-ready")
        let child = try Task6IndependentQualificationWriter(
            cacheDirectory: fixture.cacheDirectory,
            readyURL: childReady,
            qualifiedAt: task6Now.addingTimeInterval(1)
        )
        defer { child.terminateIfRunning() }
        try await task6WaitForFile(childReady)

        let parentWait = Task6LockWaitEvent()
        let parentService = fixture.relaunchedService(
            provider: Task6FixtureProvider(),
            now: task6Now.addingTimeInterval(2),
            cacheStoreHooks: SecureJSONReceiptStoreHooks(
                beforeAdvisoryLockWait: parentWait.signal
            )
        )
        let parentWriter = Task { await task6QualificationResult(from: parentService) }
        await parentWait.wait()

        externalLock.releaseAndWait()
        let parentOutcome = await parentWriter.value
        let childResult = await child.wait()
        let persisted = await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.cacheDirectory,
            includingPropertiesForKeys: nil
        )

        #expect(parentOutcome?.status == .passed)
        #expect(childResult.status == 0, "child output: \(childResult.output)")
        #expect([
            task6Now.addingTimeInterval(1),
            task6Now.addingTimeInterval(2)
        ].contains(persisted?.receipt?.qualifiedAt))
        #expect(entries.count == 1, "unexpected cache entries: \(entries.map(\.lastPathComponent))")
        #expect(entries.allSatisfy {
            !$0.lastPathComponent.hasSuffix(".quarantine") &&
                !$0.lastPathComponent.hasSuffix(".tmp")
        })
    }

    @Test func independentProcessQualificationWriterHelper() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cachePath = environment["LOCALOCR_TASK6_CHILD_CACHE"],
              let readyPath = environment["LOCALOCR_TASK6_CHILD_READY"],
              let timestamp = environment["LOCALOCR_TASK6_CHILD_TIMESTAMP"].flatMap(Double.init)
        else {
            return
        }
        let readyURL = URL(fileURLWithPath: readyPath)
        let service = LocalModelQualificationService(
            providerFactory: { _ in Task6FixtureProvider() },
            now: { Date(timeIntervalSince1970: timestamp) },
            cacheDirectory: URL(fileURLWithPath: cachePath, isDirectory: true),
            expectedCacheOwnerID: geteuid(),
            cacheStoreHooks: SecureJSONReceiptStoreHooks(
                beforeAdvisoryLockWait: {
                    try Data("ready".utf8).write(to: readyURL, options: .withoutOverwriting)
                }
            )
        )

        let outcome = try await service.qualify(task6OllamaIdentity)
        #expect(outcome.status == .passed)
        #expect(outcome.receipt?.qualifiedAt == Date(timeIntervalSince1970: timestamp))
    }

    @Test func blockedExternalLockDoesNotStarveParallelQualificationTasks() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        try await fixture.persistPassedQualification()
        let externalLock = try Task6ExternalDirectoryLock(directory: fixture.cacheDirectory)
        defer { externalLock.releaseAndWait() }
        try externalLock.waitUntilLocked()

        let blockedWait = Task6LockWaitEvent()
        let blockedService = fixture.relaunchedService(
            provider: Task6FixtureProvider(),
            cacheStoreHooks: SecureJSONReceiptStoreHooks(
                beforeAdvisoryLockWait: blockedWait.signal
            )
        )
        let blockedWriter = Task { await task6QualificationResult(from: blockedService) }
        await blockedWait.wait()

        let releasePulse = Task6QualificationCompletion()
        let releaser = Task {
            try await Task.sleep(for: .milliseconds(100))
            await releasePulse.finish(nil)
            externalLock.releaseAndWait()
        }
        let services = (0..<32).map { _ in
            fixture.relaunchedService(provider: Task6FixtureProvider())
        }
        let parallelWriters = Task {
            await withTaskGroup(of: LocalModelQualificationOutcome?.self) { group in
                for service in services {
                    group.addTask { await task6QualificationResult(from: service) }
                }
                for await _ in group {}
            }
        }

        try await releaser.value
        #expect(await releasePulse.hasFinished)
        #expect(await blockedWriter.value?.status == .passed)
        await parallelWriters.value
        #expect(await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)?.status == .passed)
    }

    @Test func cancellationWhileWaitingForExternalLockCannotMutateAfterRelease() async throws {
        let fixture = try Task6QualificationCacheFixture()
        defer { fixture.remove() }
        try await fixture.persistPassedQualification()
        let externalLock = try Task6ExternalDirectoryLock(directory: fixture.cacheDirectory)
        defer { externalLock.releaseAndWait() }
        try externalLock.waitUntilLocked()

        let lockWait = Task6LockWaitEvent()
        let failingProvider = Task6FixtureProvider(extraction: [
            .init(name: "date", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "total", value: nil, sourcePage: nil, evidence: nil),
            .init(name: "reference_number", value: nil, sourcePage: nil, evidence: nil)
        ])
        let completion = Task6QualificationCompletion()
        let service = fixture.relaunchedService(
            provider: failingProvider,
            now: task6Now.addingTimeInterval(60),
            cacheStoreHooks: SecureJSONReceiptStoreHooks(
                beforeAdvisoryLockWait: lockWait.signal
            )
        )
        let priorLive = await service.cachedOutcome(for: task6OllamaIdentity)
        #expect(priorLive?.receipt?.qualifiedAt == task6Now)
        let writer = Task {
            let outcome = await task6QualificationResult(from: service)
            await completion.finish(outcome)
        }
        await lockWait.wait()
        writer.cancel()
        #expect(await completion.hasFinished == false)

        externalLock.releaseAndWait()
        await writer.value
        #expect(await completion.outcome == nil)
        let liveAfterCancellation = await service.cachedOutcome(for: task6OllamaIdentity)
        let diskAfterCancellation = await fixture.relaunchedService()
            .cachedOutcome(for: task6OllamaIdentity)
        #expect(liveAfterCancellation?.receipt?.qualifiedAt == task6Now)
        #expect(diskAfterCancellation?.receipt?.qualifiedAt == task6Now)

        let replacement = fixture.relaunchedService(
            provider: Task6FixtureProvider(),
            now: task6Now.addingTimeInterval(120)
        )
        #expect(try await replacement.qualify(task6OllamaIdentity).status == .passed)
        #expect(await fixture.relaunchedService().cachedOutcome(for: task6OllamaIdentity)?
            .receipt?.qualifiedAt == task6Now.addingTimeInterval(120))
    }
}

let task6Now = Date(timeIntervalSince1970: 1_788_307_200)
let task6OllamaIdentity = LocalModelIdentity(
    provider: .ollama,
    model: "gemma4:8b",
    fingerprint: "sha256:fixture",
    harnessVersion: "0.11.8"
)
let task6LMStudioIdentity = LocalModelIdentity(
    provider: .lmStudio,
    model: "local/fixture-model",
    fingerprint: "sha256:lm-fixture",
    harnessVersion: "0.3.29"
)

func task6QualificationReceipt(
    identity: LocalModelIdentity = task6OllamaIdentity,
    policyVersion: Int = 1,
    fixtureVersion: Int = 1
) -> LocalModelQualificationReceipt {
    LocalModelQualificationReceipt(
        policyVersion: policyVersion,
        fixtureVersion: fixtureVersion,
        identity: identity,
        passedActions: Set(LocalIntelligenceAction.allCases),
        qualifiedAt: task6Now
    )
}

func task6Acknowledgment(
    identity: LocalModelIdentity = task6OllamaIdentity,
    policyVersion: Int = 1
) -> ExternalLocalModelAcknowledgment {
    ExternalLocalModelAcknowledgment(
        policyVersion: policyVersion,
        identity: identity,
        acceptedAt: task6Now
    )
}

func task6ExternalSelection(
    identity: LocalModelIdentity = task6OllamaIdentity,
    qualification: LocalModelQualificationReceipt? = nil,
    acknowledgment: ExternalLocalModelAcknowledgment? = nil
) -> LocalIntelligenceSelection {
    .external(
        identity: identity,
        qualification: qualification ?? task6QualificationReceipt(identity: identity),
        acknowledgment: acknowledgment ?? task6Acknowledgment(identity: identity)
    )
}

func task6QualificationService(
    provider: any DocumentIntelligenceProviding
) -> LocalModelQualificationService {
    LocalModelQualificationService(
        providerFactory: { _ in provider },
        now: { task6Now },
        cacheDirectory: nil
    )
}

func task6Provenance(
    identity: LocalModelIdentity = task6OllamaIdentity
) -> LocalModelProvenance {
    LocalModelProvenance(
        provider: identity.provider,
        providerDisplayName: identity.provider == .ollama ? "Ollama" : "LM Studio",
        model: identity.model,
        processing: .onDeviceLoopback,
        fingerprint: identity.fingerprint,
        qualifiedAt: task6Now
    )
}

private struct Task6QualificationGroundedDriver: StructuredIntelligenceSessionDriving {
    let contextSize = 4_096

    func summarize(prompt: String) async throws -> GeneratedSummary {
        guard prompt.contains("page number=\"1\"") else {
            return .init(items: [])
        }
        let evidence = "Invoice Q-104. Date: 2026-08-29. Total: $144.17."
        return .init(items: [
            .init(text: "Invoice reference Q-104.", page: 1, evidence: evidence),
            .init(text: "Invoice Q-104 has total $144.17.", page: 1, evidence: evidence)
        ])
    }

    func organize(prompt: String) async throws -> GeneratedOrganization {
        if prompt.contains("page number=\"1\"") {
            return .init(
                title: .init(value: "Invoice Q-104", page: 1, evidence: "Invoice Q-104"),
                category: nil,
                tags: []
            )
        }
        return .init(
            title: nil,
            category: .init(
                value: "LocalOCR Qualification",
                page: 2,
                evidence: "LocalOCR Qualification"
            ),
            tags: [
                .init(value: "synthetic test only", page: 2, evidence: "synthetic test only")
            ]
        )
    }

    func extract(names: [String], prompt: String) async throws -> GeneratedExtraction {
        guard prompt.contains("page number=\"1\"") else {
            return .init(fields: [])
        }
        return .init(fields: names.map { name in
            switch name {
            case "date":
                .init(name: name, value: "2026-08-29", page: 1, evidence: "Date: 2026-08-29")
            case "total":
                .init(name: name, value: "$144.17", page: 1, evidence: "Total: $144.17")
            case "reference_number":
                .init(name: name, value: "Q-104", page: 1, evidence: "Invoice Q-104")
            default:
                .init(name: name, value: nil, page: nil, evidence: nil)
            }
        })
    }
}

actor Task6FixtureProvider: DocumentIntelligenceProviding {
    nonisolated let availability: IntelligenceAvailability = .available
    private let provenance: LocalModelProvenance
    private let summary: IntelligenceSummary
    private let organization: OrganizationSuggestion
    private let extraction: [ExtractedDocumentField]
    private let failure: (any Error)?
    private(set) var summaryCount = 0
    private(set) var organizationCount = 0
    private(set) var extractionCount = 0

    init(
        identity: LocalModelIdentity = task6OllamaIdentity,
        summary: IntelligenceSummary = .init(
            text: "Invoice Q-104 totals $144.17 on 2026-08-29.",
            citations: [.init(page: 1, quote: "Invoice Q-104. Date: 2026-08-29. Total: $144.17.")]
        ),
        organization: OrganizationSuggestion = .init(
            title: "Invoice Q-104",
            category: "LocalOCR Qualification",
            tags: ["synthetic test only"],
            citations: [
                .init(page: 1, quote: "Invoice Q-104"),
                .init(page: 2, quote: "LocalOCR Qualification"),
                .init(page: 2, quote: "synthetic test only")
            ]
        ),
        extraction: [ExtractedDocumentField] = [
            .init(name: "date", value: "2026-08-29", sourcePage: 1, evidence: "Date: 2026-08-29"),
            .init(name: "total", value: "$144.17", sourcePage: 1, evidence: "Total: $144.17"),
            .init(name: "reference_number", value: "Q-104", sourcePage: 1, evidence: "Invoice Q-104")
        ],
        failure: (any Error)? = nil
    ) {
        provenance = LocalModelProvenance(
            provider: identity.provider,
            providerDisplayName: identity.provider == .ollama ? "Ollama" : "LM Studio",
            model: identity.model,
            processing: .onDeviceLoopback,
            fingerprint: identity.fingerprint,
            qualifiedAt: task6Now
        )
        self.summary = summary
        self.organization = organization
        self.extraction = extraction
        self.failure = failure
    }

    func summarize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        _ = document
        summaryCount += 1
        if let failure { throw failure }
        return .init(value: summary, model: provenance)
    }

    func organize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        _ = document
        organizationCount += 1
        if let failure { throw failure }
        return .init(value: organization, model: provenance)
    }

    func extract(_ names: [String], from document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        _ = names
        _ = document
        extractionCount += 1
        if let failure { throw failure }
        return .init(value: extraction, model: provenance)
    }
}

actor Task6SelectionStore: LocalIntelligenceSelectionStoring {
    private var storedState: LocalIntelligenceSelectionState
    private(set) var writes: [LocalIntelligenceSelectionState] = []

    init(_ state: LocalIntelligenceSelectionState) {
        storedState = state
    }

    func state() async -> LocalIntelligenceSelectionState { storedState }

    func setState(_ state: LocalIntelligenceSelectionState) {
        storedState = state
    }

    func selectApple(at date: Date) async throws {
        _ = date
        storedState = .selected(.appleSystemDefault)
        writes.append(storedState)
    }

    func selectExternal(
        _ identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    ) async throws {
        storedState = .selected(.external(
            identity: identity,
            qualification: qualification,
            acknowledgment: acknowledgment
        ))
        writes.append(storedState)
    }

    func reset(at date: Date) async throws {
        _ = date
        storedState = .none
        writes.append(storedState)
    }
}

actor Task6Transport: ModelBridgeTransporting {
    typealias Handler = @Sendable (ModelBridgeRequest) async throws -> ModelBridgeResponse
    private let handler: Handler
    private(set) var requests: [ModelBridgeRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse {
        requests.append(request)
        return try await handler(request)
    }
}

final class Task6LocatorSpy: ModelBridgeExecutableLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var resolutionCount: Int { lock.withLock { count } }

    func executableURL() throws -> URL {
        lock.withLock { count += 1 }
        throw ModelBridgeExecutableLocatorError.helperNotFound
    }
}

func task6Candidate(
    identity: LocalModelIdentity = task6OllamaIdentity,
    locality: LocalModelLocality = .verifiedLocal,
    reason: String = "Verified local fixture"
) -> BridgeModelCandidate {
    BridgeModelCandidate(
        identity: identity,
        displayName: identity.model,
        locality: locality,
        localityReason: reason
    )
}

func task6DiscoveryResponse(
    request: ModelBridgeRequest,
    candidates: [BridgeModelCandidate]
) -> ModelBridgeResponse {
    ModelBridgeResponse(id: request.id, candidates: candidates)
}

func task6GeneratedPayload(for operation: ModelBridgeOperation) -> String {
    switch operation {
    case .summarize:
        return #"{"items":[{"text":"Invoice Q-104 totals $144.17.","page":1,"evidence":"Invoice Q-104. Date: 2026-08-29. Total: $144.17."}]}"#
    case .organize:
        return #"{"title":{"value":"Invoice Q-104","page":1,"evidence":"Invoice Q-104"},"category":{"value":"LocalOCR Qualification","page":2,"evidence":"LocalOCR Qualification"},"tags":[]}"#
    case .extract:
        return #"{"fields":[{"name":"date","value":"2026-08-29","page":1,"evidence":"Date: 2026-08-29"},{"name":"total","value":"$144.17","page":1,"evidence":"Total: $144.17"},{"name":"reference_number","value":"Q-104","page":1,"evidence":"Invoice Q-104"}]}"#
    }
}

func task6PhysicalURL(_ url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
        throw CocoaError(.fileNoSuchFile)
    }
    let path = String(
        decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func task6QualificationResult(
    from service: LocalModelQualificationService
) async -> LocalModelQualificationOutcome? {
    try? await service.qualify(task6OllamaIdentity)
}

private actor Task6QualificationCompletion {
    private(set) var hasFinished = false
    private(set) var outcome: LocalModelQualificationOutcome?

    func finish(_ outcome: LocalModelQualificationOutcome?) {
        self.outcome = outcome
        hasFinished = true
    }
}

private final class Task6ExternalDirectoryLock: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let stateLock = NSLock()
    private var released = false

    init(directory: URL) throws {
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MFcntl=:flock",
            "-e",
            #"$|=1; open(my $fh, '<', $ARGV[0]) or exit 2; flock($fh, LOCK_EX) or exit 3; print "locked\n"; scalar(<STDIN>); flock($fh, LOCK_UN);"#,
            directory.path
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        self.process = process
        self.input = input
        self.output = output
    }

    func waitUntilLocked() throws {
        let line = try output.fileHandleForReading.read(upToCount: 7)
        guard line == Data("locked\n".utf8) else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    func releaseAndWait() {
        stateLock.withLock {
            guard !released else { return }
            released = true
            try? input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
    }
}

private final class Task6QualificationCacheFixture: @unchecked Sendable {
    let baseURL: URL
    let cacheDirectory: URL

    init() throws {
        baseURL = try task6PhysicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "localocr-task6-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: false)
        try #require(chmod(baseURL.path, 0o700) == 0)
        cacheDirectory = baseURL.appending(path: "qualification", directoryHint: .isDirectory)
    }

    func persistPassedQualification() async throws {
        _ = try await relaunchedService(provider: Task6FixtureProvider())
            .qualify(task6OllamaIdentity)
    }

    func relaunchedService(
        provider: any DocumentIntelligenceProviding = Task6FixtureProvider(),
        now: Date = task6Now,
        expectedCacheOwnerID: uid_t = geteuid(),
        cacheStoreHooks: SecureJSONReceiptStoreHooks = SecureJSONReceiptStoreHooks()
    ) -> LocalModelQualificationService {
        LocalModelQualificationService(
            providerFactory: { _ in provider },
            now: { now },
            cacheDirectory: cacheDirectory,
            expectedCacheOwnerID: expectedCacheOwnerID,
            cacheStoreHooks: cacheStoreHooks
        )
    }

    func onlyReceiptURL() throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.contains(".quarantine-") }
        return try #require(contents.count == 1 ? contents[0] : nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

private final class Task6LockWaitEvent: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }
}

private final class Task6IndependentQualificationWriter: @unchecked Sendable {
    private let process: Process
    private let output: Pipe

    init(
        cacheDirectory: URL,
        readyURL: URL,
        qualifiedAt: Date
    ) throws {
        let process = Process()
        let output = Pipe()
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ??
            "/Applications/Xcode.app/Contents/Developer"
        let helper = "\(developerDirectory)/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
        let frameworkPath = "\(developerDirectory)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
        try #require(FileManager.default.isExecutableFile(atPath: helper))
        try #require(FileManager.default.fileExists(atPath: frameworkPath))
        let testBundle = try #require(Bundle(for: Task6TestBundleAnchor.self).executableURL)
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [
            "--test-bundle-path", testBundle.path,
            "--testing-library", "swift-testing",
            "--filter",
            "independentProcessQualificationWriterHelper"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_FRAMEWORK_PATH"] = frameworkPath
        environment["LOCALOCR_TASK6_CHILD_CACHE"] = cacheDirectory.path
        environment["LOCALOCR_TASK6_CHILD_READY"] = readyURL.path
        environment["LOCALOCR_TASK6_CHILD_TIMESTAMP"] = String(qualifiedAt.timeIntervalSince1970)
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process
        self.output = output
    }

    func wait() async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.process.waitUntilExit()
                let data = self.output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    self.process.terminationStatus,
                    String(decoding: data, as: UTF8.self)
                ))
            }
        }
    }

    func terminateIfRunning() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

private final class Task6TestBundleAnchor: NSObject {}

private func task6WaitForFile(_ url: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: url.path) {
        guard clock.now < deadline else {
            throw CocoaError(.fileReadUnknown)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
