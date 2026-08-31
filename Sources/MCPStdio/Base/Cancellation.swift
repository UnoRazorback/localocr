/// An advisory cancellation notification for a previously-issued request.
public struct CancelledNotification: Notification {
    public static let name = "notifications/cancelled"

    public struct Parameters: Hashable, Codable, Sendable {
        public let requestId: ID?
        public let reason: String?

        public init(requestId: ID? = nil, reason: String? = nil) {
            self.requestId = requestId
            self.reason = reason
        }
    }

    public init() {}
}
