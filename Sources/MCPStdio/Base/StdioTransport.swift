import Foundation
import Logging

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
/// A bounded newline-delimited transport over caller-owned file descriptors.
public actor StdioTransport: Transport {
    /// Maximum JSON-RPC bytes in one input frame, excluding LF or CRLF.
    public static let maximumMessageBytes = 1_048_576
    // Bounds queued receive data to at most eight maximum-sized frames.
    private static let receiveBufferCapacity = 8

    public nonisolated let logger: Logger

    private enum State {
        case idle
        case connected
        case finished
    }

    private enum WritePermitOutcome: Sendable {
        case granted
        case cancelled
    }

    private struct WriteWaiter {
        let id: UUID
        let continuation: CheckedContinuation<WritePermitOutcome, Never>
    }

    private let input: FileDescriptor
    private let output: FileDescriptor
    private let messageStream: AsyncThrowingStream<Data, any Error>
    private let messageContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var state = State.idle
    private var readTask: Task<Void, Never>?
    private var writePermitHeld = false
    private var writeWaiters: [WriteWaiter] = []

    public init(
        input: FileDescriptor = .standardInput,
        output: FileDescriptor = .standardOutput,
        logger: Logger? = nil
    ) {
        self.input = input
        self.output = output
        self.logger = logger ?? Logger(label: "localocr.mcp.stdio") { _ in SwiftLogNoOpLogHandler() }

        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        messageStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.receiveBufferCapacity)) {
            continuation = $0
        }
        messageContinuation = continuation
    }

    public func connect() async throws {
        try Task.checkCancellation()
        switch state {
        case .connected:
            return
        case .finished:
            throw MCPError.internalError("stdio connection is closed")
        case .idle:
            break
        }

        do {
            try setNonBlocking(input)
            try setNonBlocking(output)
            try suppressBrokenPipeSignal(output)
        } catch {
            let transportError = MCPError.internalError("stdio connection setup failed")
            finish(throwing: transportError)
            throw transportError
        }

        state = .connected
        logger.debug("Stdio transport connected")
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func disconnect() async {
        finish()
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await acquireWritePermit()
        defer { releaseWritePermit() }
        try Task.checkCancellation()
        guard state == .connected else {
            throw MCPError.internalError("stdio connection is not connected")
        }

        var frame = data
        frame.append(UInt8(ascii: "\n"))
        var offset = 0

        while offset < frame.count {
            guard state == .connected else {
                throw MCPError.internalError("stdio connection is closed")
            }
            do {
                let written = try frame.withUnsafeBytes { bytes in
                    try output.write(UnsafeRawBufferPointer(rebasing: bytes[offset...]))
                }
                guard written > 0 else {
                    let transportError = MCPError.internalError("stdio output failed")
                    finish(throwing: transportError)
                    throw transportError
                }
                offset += written
            } catch let error where isTemporarilyUnavailable(error) {
                do {
                    try await Task.sleep(for: .milliseconds(2))
                } catch {
                    finish()
                    throw error
                }
            } catch let error as MCPError {
                throw error
            } catch {
                let transportError = MCPError.internalError("stdio output failed")
                finish(throwing: transportError)
                throw transportError
            }
        }

        logger.trace("Stdio message sent", metadata: ["bytes": "\(data.count)"])
    }

    public func receive() -> AsyncThrowingStream<Data, any Error> {
        messageStream
    }

    private func readLoop() async {
        var readBuffer = [UInt8](repeating: 0, count: 16_384)
        var pending = Data()
        pending.reserveCapacity(min(Self.maximumMessageBytes, 64 * 1_024))
        var discardingOversizedFrame = false

        while state == .connected && !Task.isCancelled {
            do {
                let byteCount = try readBuffer.withUnsafeMutableBytes { bytes in
                    try input.read(into: bytes)
                }
                if byteCount == 0 {
                    if discardingOversizedFrame {
                        finish(throwing: oversizedFrameError())
                    } else {
                        finish()
                    }
                    return
                }

                let bytes = readBuffer[..<byteCount]
                var cursor = bytes.startIndex
                while cursor < bytes.endIndex {
                    if discardingOversizedFrame {
                        guard let newline = bytes[cursor...].firstIndex(of: UInt8(ascii: "\n")) else {
                            cursor = bytes.endIndex
                            continue
                        }
                        cursor = bytes.index(after: newline)
                        finish(throwing: oversizedFrameError())
                        return
                    }

                    if let newline = bytes[cursor...].firstIndex(of: UInt8(ascii: "\n")) {
                        let fragment = bytes[cursor..<newline]
                        let endsInCarriageReturn = fragment.last == UInt8(ascii: "\r")
                            || (fragment.isEmpty && pending.last == UInt8(ascii: "\r"))
                        let framedByteCount = pending.count + fragment.count
                        let messageByteCount = framedByteCount - (endsInCarriageReturn ? 1 : 0)
                        if messageByteCount > Self.maximumMessageBytes {
                            finish(throwing: oversizedFrameError())
                            return
                        }

                        pending.append(contentsOf: fragment)
                        if endsInCarriageReturn { pending.removeLast() }
                        if !pending.isEmpty {
                            switch messageContinuation.yield(pending) {
                            case .enqueued:
                                logger.trace("Stdio message received", metadata: ["bytes": "\(pending.count)"])
                            case .dropped:
                                finish(throwing: MCPError.internalError("stdio receive capacity exceeded"))
                                return
                            case .terminated:
                                finish()
                                return
                            @unknown default:
                                finish(throwing: MCPError.internalError("stdio receive failed"))
                                return
                            }
                        }
                        pending.removeAll(keepingCapacity: true)
                        cursor = bytes.index(after: newline)
                    } else {
                        let fragment = bytes[cursor...]
                        let combinedCount = pending.count + fragment.count
                        let mayBeMaximumWithCR = combinedCount == Self.maximumMessageBytes + 1
                            && fragment.last == UInt8(ascii: "\r")
                        if combinedCount > Self.maximumMessageBytes && !mayBeMaximumWithCR {
                            pending.removeAll(keepingCapacity: false)
                            discardingOversizedFrame = true
                        } else {
                            pending.append(contentsOf: fragment)
                        }
                        cursor = bytes.endIndex
                    }
                }
            } catch let error where isTemporarilyUnavailable(error) {
                do {
                    try await Task.sleep(for: .milliseconds(2))
                } catch {
                    if state == .connected { finish() }
                    return
                }
            } catch {
                if state == .connected && !Task.isCancelled {
                    finish(throwing: MCPError.internalError("stdio input failed"))
                }
                return
            }
        }

        finish()
    }

    private func finish(throwing error: (any Error)? = nil) {
        guard state != .finished else { return }
        state = .finished
        readTask?.cancel()
        readTask = nil
        if let error {
            messageContinuation.finish(throwing: error)
        } else {
            messageContinuation.finish()
        }
        logger.debug("Stdio transport stopped")
    }

    private func acquireWritePermit() async throws {
        if !writePermitHeld {
            writePermitHeld = true
            return
        }

        let id = UUID()
        let cancellation = WriteWaiterCancellation()
        let outcome: WritePermitOutcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WritePermitOutcome, Never>) in
                if cancellation.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    writeWaiters.append(WriteWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWriteWaiter(id: id) }
        }

        if case .cancelled = outcome { throw CancellationError() }
    }

    private func releaseWritePermit() {
        if writeWaiters.isEmpty {
            writePermitHeld = false
        } else {
            writeWaiters.removeFirst().continuation.resume(returning: .granted)
        }
    }

    private func cancelWriteWaiter(id: UUID) {
        guard let index = writeWaiters.firstIndex(where: { $0.id == id }) else { return }
        writeWaiters.remove(at: index).continuation.resume(returning: .cancelled)
    }

    private func oversizedFrameError() -> MCPError {
        .parseError("message exceeds \(Self.maximumMessageBytes) bytes")
    }

    private func setNonBlocking(_ descriptor: FileDescriptor) throws {
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        guard flags >= 0, fcntl(descriptor.rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw Errno(rawValue: errno)
        }
    }

    private func suppressBrokenPipeSignal(_ descriptor: FileDescriptor) throws {
        #if canImport(Darwin)
            guard fcntl(descriptor.rawValue, F_SETNOSIGPIPE, 1) >= 0 else {
                throw Errno(rawValue: errno)
            }
        #else
            _ = descriptor
        #endif
    }

    private func isTemporarilyUnavailable(_ error: any Error) -> Bool {
        guard let errno = error as? Errno else { return false }
        return errno == .wouldBlock || errno.rawValue == EAGAIN
    }
}

private final class WriteWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
#endif
