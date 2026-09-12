import Foundation

public protocol LocalAIActivityWakeHintPosting: Sendable {
    func postRescanHint()
}

public struct NoLocalAIActivityWakeHint: LocalAIActivityWakeHintPosting {
    public init() {}

    public func postRescanHint() {}
}

#if os(macOS)
public protocol LocalAIActivityDistributedNotificationPosting: AnyObject {
    func post(
        name: Notification.Name,
        object: String?,
        userInfo: [AnyHashable: Any]?,
        deliverImmediately: Bool
    )
}

extension DistributedNotificationCenter: LocalAIActivityDistributedNotificationPosting {
    public func post(
        name: Notification.Name,
        object: String?,
        userInfo: [AnyHashable: Any]?,
        deliverImmediately: Bool
    ) {
        precondition(!deliverImmediately)
        post(name: name, object: object, userInfo: userInfo)
    }
}

public protocol LocalAIActivityMonotonicClock: Sendable {
    func now() -> Duration
    func claimRescanHint(minimumInterval: Duration) -> Bool
}

public struct SystemLocalAIActivityMonotonicClock: LocalAIActivityMonotonicClock {
    private static let processTimeBase = SystemLocalAIActivityMonotonicTimeBase()

    public init() {}

    public func now() -> Duration {
        Self.processTimeBase.now()
    }

    public func claimRescanHint(minimumInterval: Duration) -> Bool {
        Self.processTimeBase.claimRescanHint(minimumInterval: minimumInterval)
    }
}

private final class SystemLocalAIActivityMonotonicTimeBase: @unchecked Sendable {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private let lock = NSLock()
    private var lastPost: Duration?

    init() {
        origin = clock.now
    }

    func now() -> Duration {
        origin.duration(to: clock.now)
    }

    func claimRescanHint(minimumInterval: Duration) -> Bool {
        let current = now()
        return lock.withLock {
            if let lastPost, current - lastPost < minimumInterval {
                return false
            }
            lastPost = current
            return true
        }
    }
}

public final class DistributedLocalAIActivityWakeHint: LocalAIActivityWakeHintPosting, @unchecked Sendable {
    private let name: Notification.Name
    private let center: any LocalAIActivityDistributedNotificationPosting
    private let clock: any LocalAIActivityMonotonicClock

    public init(
        name: Notification.Name,
        center: any LocalAIActivityDistributedNotificationPosting,
        clock: any LocalAIActivityMonotonicClock
    ) {
        self.name = name
        self.center = center
        self.clock = clock
    }

    public func postRescanHint() {
        guard clock.claimRescanHint(minimumInterval: .seconds(1)) else { return }

        center.post(
            name: name,
            object: nil,
            userInfo: nil,
            deliverImmediately: false
        )
    }
}
#endif
