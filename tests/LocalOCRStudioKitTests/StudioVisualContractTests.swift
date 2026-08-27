@testable import LocalOCRStudioKit
import LocalOCRIntelligence
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
        #expect(contract.summaryActionLabel == "Summarize document with Local Intelligence")
        #expect(contract.organizationActionLabel == "Suggest document name and tags with Local Intelligence")
        #expect(contract.fieldsActionLabel == "Extract date, total, and reference number with Local Intelligence")
        #expect(contract.unavailableGuidance == nil)
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
