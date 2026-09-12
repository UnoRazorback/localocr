import Foundation
import Security

/// Explicit shared configuration also works for signed CLI/MCP helpers without an app Info.plist.
public enum LocalAIActivityProduction {
    public static let appGroupIdentifier = "DZ8B5454ZN.com.rayconsulting.local-ai-activity"
    public static let wakeNotificationName = "com.rayconsulting.local-ai-activity.changed"
    private static let teamIdentifier = "DZ8B5454ZN"

    public static func makeReporter() -> any LocalAIActivityReporting {
        makeReporter(
            containerResolver: {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
            },
            isAuthorized: currentCodeIsAuthorized,
            wakeHint: DistributedLocalAIActivityWakeHint(
                name: Notification.Name(wakeNotificationName),
                center: DistributedNotificationCenter.default(),
                clock: SystemLocalAIActivityMonotonicClock()
            )
        )
    }

    static func makeReporter(
        containerResolver: (String) throws -> URL?,
        isAuthorized: () -> Bool,
        clock: any LocalAIActivityClock = SystemLocalAIActivityClock(),
        wakeHint: any LocalAIActivityWakeHintPosting = NoLocalAIActivityWakeHint()
    ) -> any LocalAIActivityReporting {
        guard isAuthorized() else { return DisabledLocalAIActivityReporter() }
        do {
            guard let container = try containerResolver(appGroupIdentifier) else {
                return DisabledLocalAIActivityReporter()
            }
            let store = SecureLocalAIActivityFileStore(containerURL: container)
            try store.prepareLedgerDirectories()
            return LocalAIActivityReporter(
                ledger: LocalAIActivityLedger(store: store, clock: clock),
                clock: clock,
                wakeHint: wakeHint
            )
        } catch {
            return DisabledLocalAIActivityReporter()
        }
    }

    private static func currentCodeIsAuthorized() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess, let values = information as? [String: Any] else { return false }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return signatureIsAuthorized(
            team: values[kSecCodeInfoTeamIdentifier as String] as? String,
            groups: entitlements?["com.apple.security.application-groups"] as? [String]
        )
    }

    static func signatureIsAuthorized(team: String?, groups: [String]?) -> Bool {
        team == teamIdentifier && groups?.contains(appGroupIdentifier) == true
    }
}
