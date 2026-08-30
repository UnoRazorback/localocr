import Darwin
import Foundation

public protocol ConsentCommandIO: Sendable {
    var isTerminal: Bool { get }
    var hasPendingInput: Bool { get }
    func readLine() -> String?
    func stdout(_ text: String)
    func stderr(_ text: String)
}

public extension ConsentCommandIO {
    var hasPendingInput: Bool { true }
}

public struct StandardConsentCommandIO: ConsentCommandIO {
    private let inputFileDescriptor: Int32

    public init() {
        inputFileDescriptor = STDIN_FILENO
    }

    init(inputFileDescriptor: Int32) {
        self.inputFileDescriptor = inputFileDescriptor
    }

    public var isTerminal: Bool {
        isatty(inputFileDescriptor) != 0
    }

    public var hasPendingInput: Bool {
        var descriptor = pollfd(fd: inputFileDescriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 0)
        guard result >= 0 else {
            return true
        }
        return result > 0 && descriptor.revents != 0
    }

    public func readLine() -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        while bytes.count <= 4_096 {
            var byte: UInt8 = 0
            let count = Darwin.read(inputFileDescriptor, &byte, 1)
            if count == 0 {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 10 {
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func stdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func stderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
