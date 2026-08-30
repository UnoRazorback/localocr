import Foundation
import Testing
@testable import LocalOCRStudioKit

@Suite struct AgentClientConnectionTests {
    private let codex = AgentClientInstallation(
        kind: .codex,
        executableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        displayName: "Codex",
        version: "1.2.3"
    )
    private let claude = AgentClientInstallation(
        kind: .claudeCode,
        executableURL: URL(fileURLWithPath: "/usr/local/bin/claude"),
        displayName: "Claude Code",
        version: "2.1.207"
    )
    private let helper = URL(fileURLWithPath: "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp")

    @Test func codexUsesExactTypedArgumentsForEveryAction() {
        #expect(AgentClientCommandFactory.inspect(codex).arguments == ["mcp", "get", "localocr"])
        #expect(AgentClientCommandFactory.connect(codex, helperURL: helper).arguments == [
            "mcp", "add", "localocr", "--", helper.path,
        ])
        #expect(AgentClientCommandFactory.disconnect(codex).arguments == ["mcp", "remove", "localocr"])
    }

    @Test func claudeUsesExplicitScopeOnlyWhereItsCLIAllowsIt() {
        #expect(AgentClientCommandFactory.inspect(claude).arguments == ["mcp", "get", "localocr"])
        #expect(AgentClientCommandFactory.connect(claude, helperURL: helper, claudeScope: .local).arguments == [
            "mcp", "add", "--transport", "stdio", "--scope", "local", "localocr", "--", helper.path,
        ])
        #expect(AgentClientCommandFactory.connect(claude, helperURL: helper, claudeScope: .user).arguments == [
            "mcp", "add", "--transport", "stdio", "--scope", "user", "localocr", "--", helper.path,
        ])
        #expect(AgentClientCommandFactory.disconnect(claude, claudeScope: .user).arguments == [
            "mcp", "remove", "--scope", "user", "localocr",
        ])
    }

    @Test func helperPathRemainsOneArgumentAndNeverBecomesShellText() {
        let pathWithMetacharacters = URL(fileURLWithPath: "/tmp/Local OCR; touch nope/localocr-mcp")
        let spec = AgentClientCommandFactory.connect(codex, helperURL: pathWithMetacharacters)

        #expect(spec.executableURL == codex.executableURL)
        #expect(spec.arguments.last == pathWithMetacharacters.path)
        #expect(spec.arguments.count == 5)
        #expect(!spec.arguments.joined(separator: " ").contains("sh -c"))
    }
}
