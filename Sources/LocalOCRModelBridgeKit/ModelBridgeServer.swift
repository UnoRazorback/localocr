import Foundation
import LocalOCRModelBridgeProtocol

protocol ModelBridgeInputReading: Sendable {
    func read(upToCount count: Int) throws -> Data?
}

private struct FileHandleModelBridgeInput: ModelBridgeInputReading {
    let handle: FileHandle

    func read(upToCount count: Int) throws -> Data? {
        try handle.read(upToCount: count)
    }
}

public struct UnimplementedModelBridgeHandler: ModelBridgeHandling {
    public init() {}

    public func handle(_ request: ModelBridgeRequest) async -> ModelBridgeResponse {
        ModelBridgeResponse(
            id: request.id,
            error: ModelBridgeWireError(
                code: .providerNotImplemented,
                message: "Provider adapter is not implemented."
            )
        )
    }
}

public actor ModelBridgeServer {
    public static let maximumMessageBytes = ModelBridgeLimits.maximumMessageBytes

    private let handler: any ModelBridgeHandling
    private let responseWriter = ModelBridgeResponseWriter()

    public init(handler: any ModelBridgeHandling) {
        self.handler = handler
    }

    public func consume(_ framedRequest: Data) async -> ModelBridgeResponse {
        let hasTerminatingNewline = framedRequest.last == 10
        let payloadCount = hasTerminatingNewline ? framedRequest.count - 1 : framedRequest.count
        guard payloadCount <= Self.maximumMessageBytes else {
            return Self.errorResponse(id: 0, code: .messageTooLarge, message: "Request exceeds the one-MiB limit.")
        }
        guard hasTerminatingNewline else {
            return Self.errorResponse(id: Self.requestID(in: framedRequest), code: .invalidRequest, message: "Invalid request framing.")
        }

        let payload = framedRequest.dropLast()
        guard !payload.contains(10) else {
            return Self.errorResponse(id: Self.requestID(in: Data(payload)), code: .invalidRequest, message: "Invalid request framing.")
        }
        let data = Data(payload)
        let requestID = Self.requestID(in: data)

        if let version = Self.requestVersion(in: data), version != ModelBridgeRequest.protocolVersion {
            return Self.errorResponse(id: requestID, code: .unsupportedVersion, message: "Unsupported model bridge protocol version.")
        }

        let request: ModelBridgeRequest
        do {
            request = try JSONDecoder().decode(ModelBridgeRequest.self, from: data)
        } catch {
            return Self.errorResponse(id: requestID, code: .invalidRequest, message: "Invalid request.")
        }

        let handled = await handler.handle(request)
        return ModelBridgeResponse(
            id: request.id,
            candidates: handled.candidates,
            payloadJSON: handled.payloadJSON,
            identity: handled.identity,
            error: handled.error
        )
    }

    public func run(
        input: FileHandle,
        output: FileHandle,
        diagnostics: FileHandle
    ) async {
        await run(
            input: FileHandleModelBridgeInput(handle: input),
            output: output,
            diagnostics: diagnostics
        )
    }

    func run<Input: ModelBridgeInputReading>(
        input: Input,
        output: FileHandle,
        diagnostics: FileHandle
    ) async {
        var frame = Data()
        var discardingOversizedFrame = false

        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try input.read(upToCount: 64 * 1_024) ?? Data()
            } catch {
                Self.writeDiagnostic("model bridge input failure\n", to: diagnostics)
                return
            }
            guard !chunk.isEmpty else {
                return
            }

            for byte in chunk {
                if Task.isCancelled {
                    return
                }
                if byte == 10 {
                    let response: ModelBridgeResponse
                    if discardingOversizedFrame {
                        response = Self.errorResponse(
                            id: 0,
                            code: .messageTooLarge,
                            message: "Request exceeds the one-MiB limit."
                        )
                    } else {
                        frame.append(10)
                        response = await consume(frame)
                    }
                    frame.removeAll(keepingCapacity: true)
                    discardingOversizedFrame = false

                    do {
                        try await responseWriter.write(response, to: output)
                    } catch {
                        Self.writeDiagnostic("model bridge output failure\n", to: diagnostics)
                        return
                    }
                } else if !discardingOversizedFrame {
                    if frame.count == Self.maximumMessageBytes {
                        frame.removeAll(keepingCapacity: true)
                        discardingOversizedFrame = true
                    } else {
                        frame.append(byte)
                    }
                }
            }
        }
    }

    private static func requestID(in data: Data) -> UInt64 {
        (try? JSONDecoder().decode(RequestEnvelope.self, from: data).id) ?? 0
    }

    private static func requestVersion(in data: Data) -> Int? {
        try? JSONDecoder().decode(RequestEnvelope.self, from: data).version
    }

    private static func errorResponse(
        id: UInt64,
        code: ModelBridgeWireErrorCode,
        message: String
    ) -> ModelBridgeResponse {
        ModelBridgeResponse(id: id, error: ModelBridgeWireError(code: code, message: message))
    }

    private static func writeDiagnostic(_ diagnostic: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(diagnostic.utf8))
    }
}

private struct RequestEnvelope: Decodable {
    let version: Int?
    let id: UInt64?
}

private actor ModelBridgeResponseWriter {
    func write(_ response: ModelBridgeResponse, to output: FileHandle) throws {
        var data = try JSONEncoder().encode(response)
        if data.count > ModelBridgeLimits.maximumMessageBytes {
            data = try JSONEncoder().encode(
                ModelBridgeResponse(
                    id: response.id,
                    error: ModelBridgeWireError(
                        code: .generationFailed,
                        message: "Response exceeds the one-MiB limit."
                    )
                )
            )
        }
        data.append(10)
        try output.write(contentsOf: data)
    }
}
