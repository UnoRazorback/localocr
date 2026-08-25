@testable import LocalOCRStudioKit
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
}
