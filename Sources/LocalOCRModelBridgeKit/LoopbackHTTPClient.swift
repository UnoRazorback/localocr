import Foundation
import LocalOCRModelBridgeProtocol

public enum ApprovedLoopbackEndpoint: Sendable, Equatable {
    case ollamaVersion
    case ollamaTags
    case ollamaChat
    case lmStudioModels
    case lmStudioChat

    public var ipv4URL: URL {
        let path = switch self {
        case .ollamaVersion: "http://127.0.0.1:11434/api/version"
        case .ollamaTags: "http://127.0.0.1:11434/api/tags"
        case .ollamaChat: "http://127.0.0.1:11434/api/chat"
        case .lmStudioModels: "http://127.0.0.1:1234/api/v1/models"
        case .lmStudioChat: "http://127.0.0.1:1234/api/v1/chat"
        }
        return URL(string: path)!
    }

    public var ipv6URL: URL {
        let path = switch self {
        case .ollamaVersion: "http://[::1]:11434/api/version"
        case .ollamaTags: "http://[::1]:11434/api/tags"
        case .ollamaChat: "http://[::1]:11434/api/chat"
        case .lmStudioModels: "http://[::1]:1234/api/v1/models"
        case .lmStudioChat: "http://[::1]:1234/api/v1/chat"
        }
        return URL(string: path)!
    }

    fileprivate var method: String {
        switch self {
        case .ollamaVersion, .ollamaTags, .lmStudioModels: "GET"
        case .ollamaChat, .lmStudioChat: "POST"
        }
    }
}

public enum LoopbackHTTPError: Error, Sendable, Equatable {
    case redirectRejected
    case authenticationRejected
    case nonLoopbackResponse
    case invalidStatus(Int)
    case responseTooLarge
    case timedOut
}

public protocol LoopbackHTTPPerforming: Sendable {
    func perform(
        _ endpoint: ApprovedLoopbackEndpoint,
        body: Data?,
        timeoutMilliseconds: Int
    ) async throws -> Data
}

protocol LoopbackHTTPSessionPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public final class LoopbackHTTPClient: LoopbackHTTPPerforming, @unchecked Sendable {
    public static let maximumResponseBytes = ModelBridgeLimits.maximumMessageBytes

    private let session: any LoopbackHTTPSessionPerforming

    public init() {
        let configuration = Self.makeConfiguration()
        session = BoundedLoopbackHTTPSession(
            configuration: configuration,
            delegate: LoopbackURLSessionDelegate(),
            maximumResponseBytes: Self.maximumResponseBytes
        )
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    init(session: any LoopbackHTTPSessionPerforming) {
        self.session = session
    }

    public func perform(
        _ endpoint: ApprovedLoopbackEndpoint,
        body: Data?,
        timeoutMilliseconds: Int
    ) async throws -> Data {
        guard (1_000...120_000).contains(timeoutMilliseconds) else {
            throw LoopbackHTTPError.timedOut
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.performWithFallback(
                    endpoint,
                    body: body,
                    timeoutMilliseconds: timeoutMilliseconds,
                    deadline: deadline,
                    clock: clock
                )
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                throw LoopbackHTTPError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LoopbackHTTPError.timedOut
            }
            return result
        }
    }

    private func performWithFallback(
        _ endpoint: ApprovedLoopbackEndpoint,
        body: Data?,
        timeoutMilliseconds: Int,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> Data {
        do {
            return try await perform(
                endpoint,
                url: endpoint.ipv4URL,
                body: body,
                timeoutMilliseconds: timeoutMilliseconds
            )
        } catch let error as URLError where error.code == .cannotConnectToHost {
            guard let remainingMilliseconds = Self.remainingMilliseconds(
                until: deadline,
                clock: clock
            ) else {
                throw LoopbackHTTPError.timedOut
            }
            do {
                return try await perform(
                    endpoint,
                    url: endpoint.ipv6URL,
                    body: body,
                    timeoutMilliseconds: remainingMilliseconds
                )
            } catch let error as URLError where error.code == .timedOut {
                throw LoopbackHTTPError.timedOut
            }
        } catch let error as URLError where error.code == .timedOut {
            throw LoopbackHTTPError.timedOut
        }
    }

    private static func remainingMilliseconds(
        until deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Int? {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return nil }
        let components = remaining.components
        let millisecondsPerSecond: Int64 = 1_000
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let roundedAttoseconds = (components.attoseconds + attosecondsPerMillisecond - 1)
            / attosecondsPerMillisecond
        let milliseconds = components.seconds * millisecondsPerSecond + roundedAttoseconds
        return milliseconds > 0 ? Int(milliseconds) : nil
    }

    private func perform(
        _ endpoint: ApprovedLoopbackEndpoint,
        url: URL,
        body: Data?,
        timeoutMilliseconds: Int
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = Double(timeoutMilliseconds) / 1_000
        if endpoint.method == "POST" {
            request.httpBody = body ?? Data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes else {
            throw LoopbackHTTPError.responseTooLarge
        }
        guard let response = response as? HTTPURLResponse,
              response.url == endpoint.ipv4URL || response.url == endpoint.ipv6URL else {
            throw LoopbackHTTPError.nonLoopbackResponse
        }
        switch response.statusCode {
        case 200...299:
            return data
        case 300...399:
            throw LoopbackHTTPError.redirectRejected
        case 401, 407:
            throw LoopbackHTTPError.authenticationRejected
        default:
            throw LoopbackHTTPError.invalidStatus(response.statusCode)
        }
    }
}

private final class BoundedLoopbackHTTPSession: LoopbackHTTPSessionPerforming, @unchecked Sendable {
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(
        configuration: URLSessionConfiguration,
        delegate: URLSessionDelegate,
        maximumResponseBytes: Int
    ) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.maximumResponseBytes = maximumResponseBytes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0, maximumResponseBytes))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw LoopbackHTTPError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class LoopbackURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
