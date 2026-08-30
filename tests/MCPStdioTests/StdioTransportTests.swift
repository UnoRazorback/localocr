import Foundation
import Logging
import MCPStdio
import Testing

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin.POSIX
#endif

@Suite("StdioTransport", .serialized)
struct StdioTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func receivesOneNewlineDelimitedMessage() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        var iterator = await transport.receive().makeAsyncIterator()
        try harness.writeInput(Data(#"{"jsonrpc":"2.0"}"#.utf8) + Data("\n".utf8))

        #expect(try await iterator.next() == Data(#"{"jsonrpc":"2.0"}"#.utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func reassemblesFragmentedReadsWithoutYieldingPartialMessages() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        var iterator = await transport.receive().makeAsyncIterator()
        try harness.writeInput(Data(#"{"jsonrpc":"#.utf8))
        try await Task.sleep(for: .milliseconds(20))
        try harness.writeInput(Data(#""2.0"}"#.utf8) + Data("\n".utf8))

        #expect(try await iterator.next() == Data(#"{"jsonrpc":"2.0"}"#.utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func splitsMultipleMessagesAndNormalizesOneCarriageReturn() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        var iterator = await transport.receive().makeAsyncIterator()
        try harness.writeInput(Data("one\r\ntwo\nthree\r\r\n".utf8))

        #expect(try await iterator.next() == Data("one".utf8))
        #expect(try await iterator.next() == Data("two".utf8))
        #expect(try await iterator.next() == Data("three\r".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func burstWithoutAConsumerFailsClosedAtEightBufferedMessages() async throws {
        let captured = CapturedLog()
        let logger = Logger(label: "stdio.receive.capacity.test") { _ in
            CapturingLogHandler(captured: captured)
        }
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(
            input: harness.transportInput,
            output: harness.transportOutput,
            logger: logger
        )
        try await transport.connect()

        try harness.writeInput(Data("0\n1\n2\n3\n4\n5\n6\n7\n8\n".utf8))
        try harness.closeInputWriter()
        #expect(await captured.waitUntilContains("Stdio transport stopped"))

        var iterator = await transport.receive().makeAsyncIterator()
        let expected = ["0", "1", "2", "3", "4", "5", "6", "7"]
        for message in expected {
            #expect(try await iterator.next() == Data(message.utf8))
        }
        do {
            _ = try await iterator.next()
            Issue.record("Expected the ninth queued message to fail the connection")
        } catch let error as MCPError {
            #expect(error.code == -32603)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func eofFinishesTheReceiveStreamWithoutYieldingAnUnterminatedFragment() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()

        try harness.writeInput(Data("unterminated".utf8))
        try harness.closeInputWriter()

        #expect(try await iterator.next() == nil)
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func acceptsExactlyTheMaximumMessageSizeIncludingWithCRLF() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        var iterator = await transport.receive().makeAsyncIterator()
        let message = Data(repeating: 0x61, count: 1_048_576)

        let writer = Task.detached {
            try harness.writeInput(message + Data("\r\n".utf8))
        }
        #expect(try await iterator.next() == message)
        try await writer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsExactlyOneByteOverTheMaximumMessageSize() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let message = Data(repeating: 0x61, count: 1_048_577)

        let writer = Task.detached {
            try harness.writeInput(message + Data("\n".utf8))
        }
        do {
            _ = try await iterator.next()
            Issue.record("Expected a 1,048,577-byte message to fail framing")
        } catch let error as MCPError {
            #expect(error.code == -32700)
        }
        try await writer.value
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedMessageTerminatesFramingAndNeverYieldsFollowingLinesOrPayloadLogs() async throws {
        let captured = CapturedLog()
        var logger = Logger(label: "stdio.transport.test") { _ in CapturingLogHandler(captured: captured) }
        logger.logLevel = .trace
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput, logger: logger)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let secret = "LOCALOCR_PAYLOAD_MUST_NOT_BE_LOGGED"
        let oversized = Data((secret + String(repeating: "a", count: 1_048_577)).utf8)

        let writer = Task.detached {
            try harness.writeInput(oversized + Data("\n{}\n".utf8))
        }
        do {
            _ = try await iterator.next()
            Issue.record("Expected oversized framing to fail")
        } catch let error as MCPError {
            #expect(error.code == -32700)
        }
        try await writer.value
        #expect(captured.joinedMessages().contains(secret) == false)
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentSendsProduceWholeSingleNewlineFrames() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let messages = (0..<32).map { Data("message-\($0)".utf8) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for message in messages {
                group.addTask { try await transport.send(message) }
            }
            try await group.waitForAll()
        }
        let byteCount = messages.reduce(0) { $0 + $1.count + 1 }
        let output = try await harness.readOutput(exactly: byteCount)
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.last == "")
        #expect(lines.dropLast().count == messages.count)
        #expect(Set(lines.dropLast().map(String.init)) == Set((0..<32).map { "message-\($0)" }))
    }

    @Test(.timeLimit(.minutes(1)))
    func retriesPartialAndTemporarilyUnavailableWritesUntilTheWholeFrameIsSent() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let message = Data(repeating: 0x78, count: 262_144)
        let reader = Task { try await harness.readOutput(exactly: message.count + 1, chunkSize: 1_023) }

        try await transport.send(message)
        let output = try await reader.value

        #expect(output == message + Data("\n".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func threeQueuedLargeSendsRemainFIFOAcrossWouldBlockSuspensions() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let first = Data(repeating: 0x61, count: 131_072)
        let second = Data(repeating: 0x62, count: 131_072)
        let third = Data(repeating: 0x63, count: 131_072)
        let prefilledByteCount = try harness.fillOutputUntilWouldBlock()

        let firstSend = Task { try await transport.send(first) }
        try await Task.sleep(for: .milliseconds(5))
        let secondSend = Task { try await transport.send(second) }
        try await Task.sleep(for: .milliseconds(5))
        let thirdSend = Task { try await transport.send(third) }
        try await Task.sleep(for: .milliseconds(5))
        let reader = Task {
            try await harness.readOutput(
                exactly: prefilledByteCount + first.count + second.count + third.count + 3,
                chunkSize: 1_023
            )
        }

        try await firstSend.value
        try await secondSend.value
        try await thirdSend.value
        let framedOutput = try await reader.value.dropFirst(prefilledByteCount)
        let lines = framedOutput.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)

        #expect(lines.count == 4)
        #expect(lines.prefix(3).map { Data($0) } == [first, second, third])
    }

    @Test(.timeLimit(.minutes(1)))
    func brokenOutputPipeThrowsAContentFreeTransportErrorAndStopsTheConnection() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        try harness.closeOutputReader()

        do {
            try await transport.send(Data("sensitive payload".utf8))
            Issue.record("Expected a broken output pipe to fail")
        } catch let error as MCPError {
            #expect(error.code == -32603)
            #expect(error.message.contains("sensitive payload") == false)
        }
        do {
            _ = try await iterator.next()
            Issue.record("Expected the stopped connection to finish with its transport error")
        } catch let error as MCPError {
            #expect(error.code == -32603)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeConnectLeavesTheTransportAvailableForARealConnection() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        let gate = AsyncGate()

        let cancelledConnect = Task {
            await gate.wait()
            try await transport.connect()
        }
        cancelledConnect.cancel()
        await gate.open()
        do {
            try await cancelledConnect.value
            Issue.record("Expected the cancelled connection attempt to stop")
        } catch is CancellationError {
            // Expected. The transport must still be idle and reusable.
        }

        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        try harness.writeInput(Data("ready\n".utf8))
        #expect(try await iterator.next() == Data("ready".utf8))
        await transport.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledReceiveConsumerStopsConnectionWhenTheNextFrameCannotBeDelivered() async throws {
        let captured = CapturedLog()
        let logger = Logger(label: "stdio.consumer.cancellation.test") { _ in
            CapturingLogHandler(captured: captured)
        }
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(
            input: harness.transportInput,
            output: harness.transportOutput,
            logger: logger
        )
        try await transport.connect()
        let consumerIsWaiting = AsyncGate()
        let consumer = Task {
            var iterator = await transport.receive().makeAsyncIterator()
            await consumerIsWaiting.open()
            return try await iterator.next()
        }

        await consumerIsWaiting.wait()
        consumer.cancel()
        _ = try? await consumer.value
        try harness.writeInput(Data("abandoned-payload\n".utf8))

        #expect(await captured.waitUntilContains("Stdio transport stopped"))
        #expect(captured.joinedMessages().contains("abandoned-payload") == false)
        do {
            try await transport.send(Data("must-not-send".utf8))
            Issue.record("Expected send to reject the terminated receive connection")
        } catch is MCPError {
            // Expected after the read loop observes the terminated continuation.
        }
        do {
            try await transport.connect()
            Issue.record("Expected connect to reject the terminated receive connection")
        } catch is MCPError {
            // Expected: a stopped one-shot transport cannot reconnect.
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingASendDuringAPartialUnavailableWriteStopsWithoutHanging() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let filledBytes = try harness.fillOutputUntilWouldBlock()
        let madeRoom = try harness.readOutputSynchronously(upTo: min(8_192, filledBytes))
        #expect(madeRoom.count > 0)

        let send = Task { try await transport.send(Data(repeating: 0x7a, count: 65_536)) }
        try await Task.sleep(for: .milliseconds(20))
        send.cancel()
        do {
            try await send.value
            Issue.record("Expected the blocked send to observe cancellation")
        } catch is CancellationError {
            // Expected after at least one partial write and a would-block retry.
        }

        let remainingOutput = try harness.drainAvailableOutput()
        #expect(remainingOutput.contains(0x7a))
        #expect(try await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAQueuedSenderRemovesItsWaiterWithoutWritingLater() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        _ = try harness.fillOutputUntilWouldBlock()

        let active = Task { try await transport.send(Data(repeating: 0x61, count: 65_536)) }
        try await Task.sleep(for: .milliseconds(10))
        let completion = CompletionProbe()
        let cancelledPayload = Data(repeating: 0x7e, count: 4_096)
        let queued = Task {
            do {
                try await transport.send(cancelledPayload)
                await completion.markComplete()
            } catch {
                await completion.markComplete()
                throw error
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        queued.cancel()

        #expect(await completion.waitForCompletion(within: .milliseconds(200)))
        await transport.disconnect()
        _ = try? await active.value
        do {
            try await queued.value
            Issue.record("Expected the queued sender to throw cancellation")
        } catch is CancellationError {
            // Expected and, critically, observed before the active writer was released.
        }
        #expect(try harness.drainAvailableOutput().contains(0x7e) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func simultaneousEOFAndDisconnectFinishTheStreamOnce() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try harness.closeInputWriter() }
            group.addTask { await transport.disconnect() }
            try await group.waitForAll()
        }

        #expect(try await iterator.next() == nil)
        #expect(try await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentDisconnectCallsDuringUnavailableReadAreIdempotent() async throws {
        let harness = try PipeTransportHarness()
        defer { harness.close() }
        let transport = StdioTransport(input: harness.transportInput, output: harness.transportOutput)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { await transport.disconnect() }
            }
        }

        #expect(try await iterator.next() == nil)
        await transport.disconnect()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func waitForCompletion(within duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if isComplete { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return isComplete
    }
}

private final class PipeTransportHarness: @unchecked Sendable {
    private let inputPipe: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
    private let outputPipe: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
    private let lock = NSLock()
    private var openDescriptors: Set<CInt>

    var transportInput: FileDescriptor { inputPipe.readEnd }
    var transportOutput: FileDescriptor { outputPipe.writeEnd }

    init() throws {
        inputPipe = try FileDescriptor.pipe()
        outputPipe = try FileDescriptor.pipe()
        openDescriptors = [
            inputPipe.readEnd.rawValue,
            inputPipe.writeEnd.rawValue,
            outputPipe.readEnd.rawValue,
            outputPipe.writeEnd.rawValue,
        ]
    }

    func writeInput(_ data: Data) throws {
        try inputPipe.writeEnd.writeAll(data)
    }

    func closeInputWriter() throws {
        try close(inputPipe.writeEnd)
    }

    func closeOutputReader() throws {
        try close(outputPipe.readEnd)
    }

    func readOutput(exactly count: Int, chunkSize: Int = 4_096) async throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(chunkSize, count))
        while result.count < count {
            do {
                let desired = min(buffer.count, count - result.count)
                let bytesRead = try buffer.withUnsafeMutableBytes { rawBuffer in
                    try outputPipe.readEnd.read(into: UnsafeMutableRawBufferPointer(rebasing: rawBuffer[..<desired]))
                }
                guard bytesRead > 0 else { throw MCPError.internalError("stdio test output ended early") }
                result.append(contentsOf: buffer[..<bytesRead])
            } catch let error as Errno where error == .wouldBlock {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        return result
    }

    func fillOutputUntilWouldBlock() throws -> Int {
        let block = Data(repeating: 0x66, count: 4_096)
        var total = 0
        while true {
            do {
                total += try block.withUnsafeBytes { try outputPipe.writeEnd.write($0) }
            } catch let error as Errno where error == .wouldBlock {
                return total
            }
        }
    }

    func readOutputSynchronously(upTo count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let byteCount = try buffer.withUnsafeMutableBytes { bytes in
            try outputPipe.readEnd.read(into: bytes)
        }
        return Data(buffer[..<byteCount])
    }

    func drainAvailableOutput() throws -> Data {
        #if canImport(Darwin)
            let flags = fcntl(outputPipe.readEnd.rawValue, F_GETFL)
            guard flags >= 0, fcntl(outputPipe.readEnd.rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Errno(rawValue: errno)
            }
        #endif
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            do {
                let count = try buffer.withUnsafeMutableBytes { try outputPipe.readEnd.read(into: $0) }
                if count == 0 { return result }
                result.append(contentsOf: buffer[..<count])
            } catch let error as Errno where error == .wouldBlock {
                return result
            }
        }
    }

    func close() {
        let descriptors = lock.withLock {
            let descriptors = openDescriptors
            openDescriptors.removeAll()
            return descriptors
        }
        for descriptor in descriptors {
            try? FileDescriptor(rawValue: descriptor).close()
        }
    }

    private func close(_ descriptor: FileDescriptor) throws {
        let shouldClose = lock.withLock { openDescriptors.remove(descriptor.rawValue) != nil }
        if shouldClose { try descriptor.close() }
    }
}

private final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ value: String) { lock.withLock { messages.append(value) } }
    func joinedMessages() -> String { lock.withLock { messages.joined(separator: "\n") } }

    func waitUntilContains(_ value: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if joinedMessages().contains(value) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return joinedMessages().contains(value)
    }
}

private struct CapturingLogHandler: LogHandler {
    let captured: CapturedLog
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        captured.append("\(event.message) \(event.metadata ?? [:])")
    }
}
