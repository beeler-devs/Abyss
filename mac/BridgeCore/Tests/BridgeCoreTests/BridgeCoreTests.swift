import Foundation
import Testing
@testable import BridgeCore

@Test("Workspace policy allows path inside workspace")
func workspacePolicyAllowsNestedPath() throws {
    let root = URL(fileURLWithPath: "/tmp/bridge-policy-workspace")
    let policy = WorkspacePolicy(workspaceRoot: root)

    let resolved = try policy.resolve(relativePath: "src/main.swift")
    #expect(resolved.path == "/tmp/bridge-policy-workspace/src/main.swift")
}

@Test("Workspace policy rejects parent traversal")
func workspacePolicyRejectsTraversal() {
    let root = URL(fileURLWithPath: "/tmp/bridge-policy-workspace")
    let policy = WorkspacePolicy(workspaceRoot: root)

    #expect(throws: Error.self) {
        try policy.resolve(relativePath: "../secrets.txt")
    }
}

@Test("Process executor truncates long output")
func processExecutorTruncatesOutput() throws {
    let executor = ProcessExecutor()
    let result = try executor.run(
        command: "python - <<'PY'\nprint('x' * 5000)\nPY",
        cwd: URL(fileURLWithPath: "/tmp"),
        timeoutSec: 5,
        outputLimitBytes: 512
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("...[truncated]"))
}

@Test("Process executor times out")
func processExecutorTimesOut() throws {
    let executor = ProcessExecutor()
    let result = try executor.run(
        command: "sleep 2",
        cwd: URL(fileURLWithPath: "/tmp"),
        timeoutSec: 1,
        outputLimitBytes: 512
    )

    #expect(result.timedOut == true)
    #expect(result.exitCode == -1)
    #expect(result.stderr.contains("timed out"))
}
