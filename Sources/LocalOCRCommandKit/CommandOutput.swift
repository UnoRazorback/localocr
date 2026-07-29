public struct CommandOutput: Sendable {
    public let stdout: @Sendable (String) -> Void
    public let stderr: @Sendable (String) -> Void

    public init(
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) {
        self.stdout = stdout
        self.stderr = stderr
    }
}
