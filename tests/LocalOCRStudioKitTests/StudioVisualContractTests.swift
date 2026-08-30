@testable import LocalOCRStudioKit
import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
import Testing

@Suite struct StudioVisualContractTests {
    @Test func compactCornerMarkDropsScanRulesButKeepsPageSilhouette() {
        #expect(StudioCornerMarkContract(pointSize: 40).showsScanRules == false)
        #expect(StudioCornerMarkContract(pointSize: 60).showsScanRules == true)
        #expect(StudioCornerMarkContract(pointSize: 1024).showsFold == true)
    }

    @Test func appearanceResolvesApprovedSemanticPalette() {
        let light = LocalOCRStudioPalette(appearance: .light)
        let dark = LocalOCRStudioPalette(appearance: .dark)

        #expect(light.groundHex == "F4F2EC")
        #expect(light.inkHex == "17160F")
        #expect(light.accentHex == "4A5729")
        #expect(dark.groundHex == "121210")
        #expect(dark.inkHex == "F2F0E9")
        #expect(dark.accentHex == "AEC072")
    }

    @Test func privacyBadgeCommunicatesStatusWithoutExposingDocumentData() {
        let contract = StudioOnDeviceBadgeContract()

        #expect(contract.title == "On device")
        #expect(contract.accessibilityLabel == "On device, documents stay on this Mac")
        #expect(contract.isInteractive == false)
    }

    @Test func localIntelligenceActionsHaveMeaningfulAccessibleLabels() {
        let contract = StudioLocalIntelligenceContract(availability: .available)

        #expect(contract.title == "Local Intelligence")
        #expect(contract.manageModelsLabel == "Manage Local Models")
        #expect(
            contract.modelExplanation
                == "Apple selects the installed system model. macOS does not expose its specific model name or version."
        )
        #expect(contract.summaryActionLabel == "Summarize document with Local Intelligence")
        #expect(contract.organizationActionLabel == "Suggest document name and tags with Local Intelligence")
        #expect(contract.fieldsActionLabel == "Extract date, total, and reference number with Local Intelligence")
        #expect(contract.unavailableGuidance == nil)
    }

    @Test func processingRouteUsesActualProvenanceAndSanitizesOnlyDisplayText() {
        let apple = StudioProcessingRoute(provenance: .appleSystemDefault)
        #expect(apple.path == "LocalOCR → Apple system model")
        #expect(apple.modelDisclosure == "Apple Foundation Models — system default")
        #expect(apple.location == "On device")

        let identity = LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:\u{202E}8b",
            fingerprint: "sha256:fixture",
            harnessVersion: "1.0.0"
        )
        let provenance = LocalModelProvenance(
            provider: .ollama,
            providerDisplayName: "Ollama\nfor Mac",
            model: identity.model,
            processing: .onDeviceLoopback,
            fingerprint: identity.fingerprint,
            qualifiedAt: Date(timeIntervalSince1970: 1_788_050_400)
        )
        let external = StudioProcessingRoute(provenance: provenance)

        #expect(external.path == "LocalOCR → loopback on this Mac → Ollama for Mac")
        #expect(external.modelDisclosure == "Ollama for Mac — gemma4:8b")
        #expect(external.location == "On device via loopback")
        #expect(
            external.accessibilityText
                == "Processing route: LocalOCR → loopback on this Mac → Ollama for Mac. Ollama for Mac — gemma4:8b. On device via loopback."
        )
        #expect(identity.model == "gemma4:\u{202E}8b")
    }

    @Test func exactModelIdentityProducesAStableBoundedAccessibilityKey() {
        let identity = LocalModelIdentity(
            provider: .lmStudio,
            model: "local-metadata-missing",
            fingerprint: "sha256:unverified",
            harnessVersion: "0.3.20"
        )

        let key = StudioModelAccessibilityKey.key(for: identity)

        #expect(key == "d53117af31bcb08f8b4768dd4b999cf4667a4314b098e4e6562687cb6d3ea7c9")
        #expect(key.utf8.count == 64)
    }

    @Test func managerContractKeepsApprovedCopyAndProhibitedControlsOut() {
        let contract = StudioLocalModelManagerContract()

        #expect(contract.title == "Manage Local Models")
        #expect(contract.discoveryExplanation == "Detection checks only local model details; it does not send document text.")
        #expect(contract.confirmationStatement == StudioExternalModelConfirmation.approvedStatement)
        #expect(contract.providerTitles == ["APPLE", "OLLAMA", "LM STUDIO"])
        #expect(contract.allowedActions == [
            "Detect", "Test", "Recheck", "Select", "Reset selection", "Done",
            "Continue", "Cancel", "Retry", "Choose Another Local Model", "Use Apple System Model",
        ])
        let prohibited = [
            "Install", "Pull", "Download", "Delete", "Load", "Unload", "Start", "Stop",
            "Server setup", "Credential", "URL", "Port", "Configure",
        ]
        #expect(Set(contract.allowedActions).isDisjoint(with: prohibited))
    }

    @Test(arguments: [
        (IntelligenceAvailability.requiresMacOS26, "Local Intelligence requires macOS 26 or later."),
        (IntelligenceAvailability.deviceNotEligible, "This Mac is not eligible for Apple Intelligence."),
        (IntelligenceAvailability.appleIntelligenceNotEnabled, "Turn on Apple Intelligence in System Settings to use Local Intelligence."),
        (IntelligenceAvailability.modelNotReady, "Apple Intelligence is downloading or not ready yet. Try again when setup is complete."),
        (IntelligenceAvailability.unsupportedLanguage, "The current Apple Intelligence language is not supported."),
    ])
    func localIntelligenceAvailabilityExplainsRecovery(
        availability: IntelligenceAvailability,
        guidance: String
    ) {
        #expect(
            StudioLocalIntelligenceContract(availability: availability)
                .unavailableGuidance == guidance
        )
    }
}
