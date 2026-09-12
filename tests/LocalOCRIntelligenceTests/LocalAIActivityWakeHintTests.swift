import Foundation
@testable import LocalOCRIntelligence
import Testing

#if os(macOS)
@Suite struct LocalAIActivityWakeHintTests {
    // Catches a configured hint that substitutes a built-in name, includes payload, or changes delivery semantics.
    @Test func distributedHintPostsOnlyInjectedNameWithoutPayload() {
        let center = SpyDistributedNotificationCenter()
        let clock = TestMonotonicClock(now: .seconds(42))
        let name = Notification.Name("test.local-ai-activity.rescan")
        let hint = DistributedLocalAIActivityWakeHint(name: name, center: center, clock: clock)

        hint.postRescanHint()

        #expect(center.posts == [
            .init(name: name, objectWasNil: true, userInfoWasNil: true, deliverImmediately: false)
        ])
    }

    // Catches a rate limiter that allows duplicate posts inside one second or suppresses the exact one-second boundary.
    @Test func distributedHintAllowsAtMostOnePostPerSecond() {
        let center = SpyDistributedNotificationCenter()
        let clock = TestMonotonicClock(now: .zero)
        let name = Notification.Name("test.local-ai-activity.rescan")
        let hint = DistributedLocalAIActivityWakeHint(name: name, center: center, clock: clock)

        hint.postRescanHint()
        clock.advance(by: .milliseconds(999))
        hint.postRescanHint()
        clock.advance(by: .milliseconds(1))
        hint.postRescanHint()

        #expect(center.posts == [
            .init(name: name, objectWasNil: true, userInfoWasNil: true, deliverImmediately: false),
            .init(name: name, objectWasNil: true, userInfoWasNil: true, deliverImmediately: false)
        ])
    }

    // Catches per-instance limiter state that lets two hints in one process both post inside the same second.
    @Test func distributedHintInstancesShareOneProcessRateLimit() {
        let center = SpyDistributedNotificationCenter()
        let clock = TestMonotonicClock(now: .zero)
        let name = Notification.Name("test.local-ai-activity.rescan")
        let first = DistributedLocalAIActivityWakeHint(name: name, center: center, clock: clock)
        let second = DistributedLocalAIActivityWakeHint(name: name, center: center, clock: clock)

        first.postRescanHint()
        second.postRescanHint()

        #expect(center.posts == [
            .init(name: name, objectWasNil: true, userInfoWasNil: true, deliverImmediately: false)
        ])
    }
}

private struct DistributedPost: Equatable {
    let name: Notification.Name
    let objectWasNil: Bool
    let userInfoWasNil: Bool
    let deliverImmediately: Bool
}

private final class SpyDistributedNotificationCenter: LocalAIActivityDistributedNotificationPosting {
    private(set) var posts: [DistributedPost] = []

    func post(
        name: Notification.Name,
        object: String?,
        userInfo: [AnyHashable: Any]?,
        deliverImmediately: Bool
    ) {
        posts.append(.init(
            name: name,
            objectWasNil: object == nil,
            userInfoWasNil: userInfo == nil,
            deliverImmediately: deliverImmediately
        ))
    }
}

private final class TestMonotonicClock: LocalAIActivityMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Duration
    private var lastPost: Duration?

    init(now: Duration) {
        instant = now
    }

    func now() -> Duration {
        lock.withLock { instant }
    }

    func claimRescanHint(minimumInterval: Duration) -> Bool {
        lock.withLock {
            if let lastPost, instant - lastPost < minimumInterval {
                return false
            }
            lastPost = instant
            return true
        }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant += duration }
    }
}
#endif
