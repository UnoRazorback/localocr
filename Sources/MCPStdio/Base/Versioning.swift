/// MCP protocol versions supported by this source snapshot.
public enum Version {
    public static let supported: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latest = "2025-06-18"

    public static func negotiate(clientRequestedVersion: String) -> String {
        supported.contains(clientRequestedVersion) ? clientRequestedVersion : latest
    }
}
