import Foundation
@testable import LocalOCRModelBridgeKit
import Testing

@Suite("Fixed loopback HTTP client")
struct LoopbackHTTPClientTests {
    @Test
    func approvedEndpointsResolveOnlyToLiteralProviderLoopbackURLs() {
        let expected: [(ApprovedLoopbackEndpoint, String, String)] = [
            (.ollamaVersion, "http://127.0.0.1:11434/api/version", "http://[::1]:11434/api/version"),
            (.ollamaTags, "http://127.0.0.1:11434/api/tags", "http://[::1]:11434/api/tags"),
            (.ollamaChat, "http://127.0.0.1:11434/api/chat", "http://[::1]:11434/api/chat"),
            (.lmStudioModels, "http://127.0.0.1:1234/api/v1/models", "http://[::1]:1234/api/v1/models"),
            (.lmStudioChat, "http://127.0.0.1:1234/api/v1/chat", "http://[::1]:1234/api/v1/chat")
        ]

        for (endpoint, ipv4, ipv6) in expected {
            #expect(endpoint.ipv4URL.absoluteString == ipv4)
            #expect(endpoint.ipv6URL.absoluteString == ipv6)
        }
    }

    @Test
    func redirectResponseIsRejectedInsteadOfFollowed() async {
        let session = FixtureLoopbackHTTPSession(
            responses: [
                .init(
                    data: Data(),
                    response: HTTPURLResponse(
                        url: URL(string: "http://127.0.0.1:11434/api/chat")!,
                        statusCode: 302,
                        httpVersion: nil,
                        headerFields: ["Location": "https://example.com/collect"]
                    )!
                )
            ]
        )
        let client = LoopbackHTTPClient(session: session)

        await #expect(throws: LoopbackHTTPError.redirectRejected) {
            try await client.perform(.ollamaChat, body: Data("{}".utf8), timeoutMilliseconds: 1_000)
        }
        #expect(await session.requestCount == 1)
    }

    @Test
    func productionConfigurationDisablesAmbientNetworkState() {
        let configuration = LoopbackHTTPClient.makeConfiguration()

        #expect(configuration.identifier == nil)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.waitsForConnectivity == false)
    }

    @Test
    func endpointControlsMethodHeadersAndBody() async throws {
        let session = FixtureLoopbackHTTPSession(
            responses: [
                okResponse(for: .ollamaTags),
                okResponse(for: .ollamaChat)
            ]
        )
        let client = LoopbackHTTPClient(session: session)

        _ = try await client.perform(
            .ollamaTags,
            body: Data("forbidden GET body".utf8),
            timeoutMilliseconds: 1_000
        )
        _ = try await client.perform(
            .ollamaChat,
            body: Data("{\"safe\":true}".utf8),
            timeoutMilliseconds: 1_000
        )
        let requests = await session.requests

        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].allHTTPHeaderFields?.isEmpty != false)
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].httpBody == Data("{\"safe\":true}".utf8))
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test
    func connectionFailureRetriesOnlyTheLiteralIPv6Endpoint() async throws {
        let session = FixtureLoopbackHTTPSession(
            outcomes: [
                .urlError(.cannotConnectToHost),
                .response(okResponse(for: .ollamaVersion, ipv6: true))
            ]
        )
        let client = LoopbackHTTPClient(session: session)

        _ = try await client.perform(.ollamaVersion, body: nil, timeoutMilliseconds: 1_000)

        #expect(await session.requests.map(\.url) == [
            ApprovedLoopbackEndpoint.ollamaVersion.ipv4URL,
            ApprovedLoopbackEndpoint.ollamaVersion.ipv6URL
        ])
    }

    @Test
    func nonLoopbackResponseURLIsRejected() async {
        let remote = HTTPURLResponse(
            url: URL(string: "https://example.com/api/tags")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let client = LoopbackHTTPClient(
            session: FixtureLoopbackHTTPSession(responses: [.init(data: Data(), response: remote)])
        )

        await #expect(throws: LoopbackHTTPError.nonLoopbackResponse) {
            try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)
        }
    }

    @Test(arguments: [401, 407])
    func authenticationResponsesAreRejected(status: Int) async {
        let response = HTTPURLResponse(
            url: ApprovedLoopbackEndpoint.ollamaTags.ipv4URL,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        let client = LoopbackHTTPClient(
            session: FixtureLoopbackHTTPSession(responses: [.init(data: Data(), response: response)])
        )

        await #expect(throws: LoopbackHTTPError.authenticationRejected) {
            try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)
        }
    }

    @Test
    func oversizedResponseIsRejected() async {
        let client = LoopbackHTTPClient(
            session: FixtureLoopbackHTTPSession(
                responses: [
                    .init(
                        data: Data(repeating: 65, count: LoopbackHTTPClient.maximumResponseBytes + 1),
                        response: okResponse(for: .ollamaTags).response
                    )
                ]
            )
        )

        await #expect(throws: LoopbackHTTPError.responseTooLarge) {
            try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)
        }
    }

    @Test
    func sessionTimeoutIsMappedToStableError() async {
        let client = LoopbackHTTPClient(
            session: FixtureLoopbackHTTPSession(outcomes: [.urlError(.timedOut)])
        )

        await #expect(throws: LoopbackHTTPError.timedOut) {
            try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)
        }
    }

    @Test
    func ipv6FallbackTimeoutIsMappedToStableError() async {
        let client = LoopbackHTTPClient(
            session: FixtureLoopbackHTTPSession(
                outcomes: [.urlError(.cannotConnectToHost), .urlError(.timedOut)]
            )
        )

        await #expect(throws: LoopbackHTTPError.timedOut) {
            try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)
        }
    }

    @Test
    func ipv6FallbackUsesOnlyTheRemainingOverallTimeout() async throws {
        let session = FixtureLoopbackHTTPSession(
            outcomes: [
                .delayedURLError(.cannotConnectToHost, milliseconds: 200),
                .response(okResponse(for: .ollamaTags, ipv6: true))
            ]
        )
        let client = LoopbackHTTPClient(session: session)

        _ = try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)

        let requests = await session.requests
        #expect(requests.count == 2)
        #expect(requests[0].timeoutInterval == 1.0)
        #expect(requests[1].timeoutInterval > 0)
        #expect(requests[1].timeoutInterval < 0.9)
    }

    @Test
    func overallDeadlineCancelsSlowDripDespiteContinuousProgress() async {
        let cancellation = HTTPTransferCancellationProbe()
        let client = LoopbackHTTPClient(
            session: SlowDripLoopbackHTTPSession(cancellation: cancellation)
        )
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: LoopbackHTTPError.timedOut) {
            try await client.perform(.ollamaTags, body: nil, timeoutMilliseconds: 1_000)
        }

        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .milliseconds(1_400))
        #expect(cancellation.wasCancelled)
    }
}

private actor FixtureLoopbackHTTPSession: LoopbackHTTPSessionPerforming {
    struct Response: Sendable {
        let data: Data
        let response: URLResponse
    }

    enum Outcome: Sendable {
        case response(Response)
        case urlError(URLError.Code)
        case delayedURLError(URLError.Code, milliseconds: Int)
    }

    private var outcomes: [Outcome]
    private(set) var requestCount = 0
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        outcomes = responses.map(Outcome.response)
    }

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        requests.append(request)
        switch outcomes.removeFirst() {
        case let .response(response):
            return (response.data, response.response)
        case let .urlError(code):
            throw URLError(code)
        case let .delayedURLError(code, milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
            throw URLError(code)
        }
    }
}

private func okResponse(
    for endpoint: ApprovedLoopbackEndpoint,
    ipv6: Bool = false
) -> FixtureLoopbackHTTPSession.Response {
    .init(
        data: Data("{}".utf8),
        response: HTTPURLResponse(
            url: ipv6 ? endpoint.ipv6URL : endpoint.ipv4URL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    )
}

private actor SlowDripLoopbackHTTPSession: LoopbackHTTPSessionPerforming {
    private let cancellation: HTTPTransferCancellationProbe

    init(cancellation: HTTPTransferCancellationProbe) {
        self.cancellation = cancellation
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            var data = Data()
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(75))
                data.append(65)
            }
            return (
                data,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        } onCancel: {
            cancellation.markCancelled()
        }
    }
}

private final class HTTPTransferCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func markCancelled() {
        lock.withLock { cancelled = true }
    }
}
