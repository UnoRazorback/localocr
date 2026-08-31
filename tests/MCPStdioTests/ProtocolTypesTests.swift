import Foundation
import MCPStdio
import Testing

@Suite struct ProtocolTypesTests {
    @Test func initializeRequestRoundTripsWithIntegerStringAndNullIDs() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let cases: [(Data, ID)] = [
            (Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8), .int(1)),
            (Data(#"{"jsonrpc":"2.0","id":"request-1","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8), .string("request-1")),
            (Data(#"{"jsonrpc":"2.0","id":null,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8), .null)
        ]

        for (data, expectedID) in cases {
            let request = try decoder.decode(Request<Initialize>.self, from: data)
            #expect(request.id == expectedID)
            #expect(try decoder.decode(Request<Initialize>.self, from: encoder.encode(request)) == request)
        }
    }

    @Test func valuePreservesEveryWireCase() throws {
        let values: [Value] = [
            .null,
            .bool(true),
            .int(42),
            .double(2.5),
            .string("local"),
            .data(mimeType: "text/plain", Data("hi".utf8)),
            .array([.string("item"), .int(2)]),
            .object(["nested": .bool(false)])
        ]

        for value in values {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(Value.self, from: data) == value)
        }
    }

    @Test func valueMatchesUpstreamDataURLDefaultsAndPercentDecoding() throws {
        let defaultMIME = Value.data(Data("plain".utf8))
        let defaultMIMEURL = try JSONDecoder().decode(String.self, from: JSONEncoder().encode(defaultMIME))
        let percentEncoded = Data(#""data:text/plain;charset=utf-8,hello%20world""#.utf8)
        let implicitMIME = Data(#""data:,hello%20world""#.utf8)

        #expect(defaultMIMEURL == "data:text/plain;base64,cGxhaW4=")
        #expect(try JSONDecoder().decode(Value.self, from: percentEncoded) == .data(mimeType: "text/plain;charset=utf-8", Data("hello world".utf8)))
        #expect(try JSONDecoder().decode(Value.self, from: implicitMIME) == .data(mimeType: "text/plain", Data("hello world".utf8)))
    }

    @Test func toolMessagesPreserveAnnotationsSchemasArgumentsAndResults() throws {
        let tool = Tool(
            name: "inspect_pdf",
            title: "Inspect PDF",
            description: "Inspects a local PDF.",
            inputSchema: .object(["type": .string("object")]),
            annotations: .init(
                title: "Inspect",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            outputSchema: .object(["type": .string("object")])
        )
        let list = ListTools.Result(tools: [tool])
        let call = CallTool.request(id: .string("call-1"), .init(
            name: "inspect_pdf",
            arguments: ["file_path": .string("/tmp/fixture.pdf")]
        ))
        let result = CallTool.response(id: .string("call-1"), result: .init(
            content: [.text(text: "{\"pages\":2}", annotations: nil, _meta: nil)],
            structuredContent: .object(["pages": .int(2)])
        ))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ListTools.Result.self, from: encoder.encode(list)) == list)
        #expect(try decoder.decode(Request<CallTool>.self, from: encoder.encode(call)) == call)
        #expect(try decoder.decode(Response<CallTool>.self, from: encoder.encode(result)) == result)
    }

    @Test func genericStructuredResultInitializerUsesTheValueOverloadWithoutRecursion() throws {
        let result = try CallTool.Result(
            structuredContent: GenericStructuredOutput(message: "completed", count: 2)
        )

        #expect(result.structuredContent == .object([
            "count": .int(2),
            "message": .string("completed"),
        ]))
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CallTool.Result.self, from: encoded)
        #expect(decoded == result)
    }

    @Test func toolDecodingDefaultsOmittedAnnotationsToEmpty() throws {
        let data = Data(#"{"name":"inspect_pdf","description":"Inspects a local PDF.","inputSchema":{"type":"object"}}"#.utf8)
        let tool = try JSONDecoder().decode(Tool.self, from: data)

        #expect(tool.annotations.isEmpty)
    }

    @Test func pingAndCancellationUseTheirExactMCPMethods() throws {
        let ping = Ping.request(id: .int(7))
        let cancellation = Message<CancelledNotification>(params: .init(requestId: .string("slow-call"), reason: "client closed"))
        let initialized = Message<InitializedNotification>(params: .init())
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(Request<Ping>.self, from: encoder.encode(ping)) == ping)
        #expect(try decoder.decode(Message<CancelledNotification>.self, from: encoder.encode(cancellation)) == cancellation)
        #expect(try decoder.decode(Message<InitializedNotification>.self, from: encoder.encode(initialized)) == initialized)
        let cancellationJSON = String(decoding: try encoder.encode(cancellation), as: UTF8.self)
            .replacingOccurrences(of: #"\/"#, with: "/")
        #expect(cancellationJSON.contains("notifications/cancelled"))
    }

    @Test func protocolErrorsEncodeWithTheJSONRPCCodeMessageAndDetail() throws {
        let error = MCPError.invalidParams("file_path is required")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(error)) as? [String: Any]

        #expect(encoded?["code"] as? Int == -32602)
        #expect(encoded?["message"] as? String == "Invalid params: file_path is required")
        #expect((encoded?["data"] as? [String: String])?["detail"] == "file_path is required")
        #expect(try JSONDecoder().decode(MCPError.self, from: JSONEncoder().encode(error)) == error)
    }

    @Test func protocolErrorsDecodePeerDetailsFromJSONRPCValueDataOrMessageFallback() throws {
        let decoder = JSONDecoder()
        let structuredData = Data(#"{"code":-32602,"message":"Invalid params: file_path is required","data":{"detail":"file_path is required","attempt":1}}"#.utf8)
        let messageOnly = Data(#"{"code":-32603,"message":"worker failed"}"#.utf8)

        #expect(try decoder.decode(MCPError.self, from: structuredData) == .invalidParams("file_path is required"))
        #expect(try decoder.decode(MCPError.self, from: messageOnly) == .internalError("worker failed"))
    }
}

private struct GenericStructuredOutput: Codable {
    let message: String
    let count: Int
}
