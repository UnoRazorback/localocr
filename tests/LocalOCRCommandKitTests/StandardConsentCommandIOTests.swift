import Darwin
import Foundation
import Testing
@testable import LocalOCRCommandKit

@Suite(.serialized) struct StandardConsentCommandIOTests {
    @Test(arguments: ["y", "yes"])
    func readsExactAcknowledgmentsFromARealPseudoTerminal(_ answer: String) throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let io = StandardConsentCommandIO(inputFileDescriptor: pty.slave)

        try pty.write(answer + "\n")

        #expect(io.isTerminal)
        #expect(io.readLine() == answer)
        #expect(!io.hasPendingInput)
    }

    @Test func detectsQueuedExtraInputOnARealPseudoTerminal() throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let io = StandardConsentCommandIO(inputFileDescriptor: pty.slave)

        try pty.write("yes\nextra\n")

        #expect(io.readLine() == "yes")
        #expect(io.hasPendingInput)
    }

    @Test func returnsNilAtPseudoTerminalEOF() throws {
        let pty = try PseudoTerminal()
        let io = StandardConsentCommandIO(inputFileDescriptor: pty.slave)
        pty.closeMaster()
        defer { pty.closeSlave() }

        #expect(io.readLine() == nil)
    }
}

private final class PseudoTerminal {
    private(set) var master: Int32 = -1
    private(set) var slave: Int32 = -1

    init() throws {
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == bytes.count else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func closeMaster() {
        if master >= 0 { Darwin.close(master); master = -1 }
    }

    func closeSlave() {
        if slave >= 0 { Darwin.close(slave); slave = -1 }
    }

    func close() {
        closeMaster()
        closeSlave()
    }
}
