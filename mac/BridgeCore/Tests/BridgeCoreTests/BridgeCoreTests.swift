import Foundation
import Testing
@testable import BridgeCore

@Test("Workspace policy allows path inside allowlisted roots")
func workspacePolicyAllowsAllowlistedRoots() throws {
    let policy = WorkspacePolicy(workspaceRoots: [
        URL(fileURLWithPath: "/tmp/bridge-policy-1"),
        URL(fileURLWithPath: "/tmp/bridge-policy-2"),
    ])

    let first = try policy.resolve(relativePath: "src/main.swift")
    #expect(first.path == "/tmp/bridge-policy-1/src/main.swift")

    let second = try policy.resolve(path: "/tmp/bridge-policy-2/README.md", relativeTo: policy.primaryWorkspaceRoot)
    #expect(second.path == "/tmp/bridge-policy-2/README.md")
}

@Test("Workspace policy rejects traversal and denylisted paths")
func workspacePolicyRejectsTraversalAndDenylist() {
    let policy = WorkspacePolicy(workspaceRoot: URL(fileURLWithPath: "/tmp/bridge-policy-workspace"))

    #expect(throws: Error.self) {
        try policy.resolve(relativePath: "../secrets.txt")
    }

    #expect(throws: Error.self) {
        try policy.resolve(relativePath: ".env")
    }

    #expect(throws: Error.self) {
        try policy.resolve(relativePath: "keys/id_rsa")
    }
}

@Test("Command manager enforces timeout")
func commandManagerTimeout() async throws {
    let manager = CommandManager(tailLimitBytes: 16_000, chunkLimitBytes: 1024, timeoutCapSec: 30)

    let started = try await manager.start(
        command: "sleep 2",
        cwd: URL(fileURLWithPath: "/tmp"),
        env: nil,
        timeoutSec: 1
    )

    guard let completion = await manager.waitForCompletion(commandId: started.commandId) else {
        Issue.record("Expected completion")
        return
    }

    #expect(completion.state == .timedOut)
}

@Test("Command manager supports cancellation")
func commandManagerCancellation() async throws {
    let manager = CommandManager(tailLimitBytes: 16_000, chunkLimitBytes: 1024, timeoutCapSec: 30)

    let started = try await manager.start(
        command: "sleep 10",
        cwd: URL(fileURLWithPath: "/tmp"),
        env: nil,
        timeoutSec: 20
    )

    try await Task.sleep(nanoseconds: 200_000_000)
    let cancelled = await manager.cancel(commandId: started.commandId)
    #expect(cancelled == true)

    guard let completion = await manager.waitForCompletion(commandId: started.commandId) else {
        Issue.record("Expected completion")
        return
    }

    #expect(completion.state == .cancelled)
}

@Test("Command manager truncates tail output")
func commandManagerTailTruncation() async throws {
    let manager = CommandManager(tailLimitBytes: 256, chunkLimitBytes: 64, timeoutCapSec: 30)

    let started = try await manager.start(
        command: "python - <<'PY'\nprint('x' * 5000)\nPY",
        cwd: URL(fileURLWithPath: "/tmp"),
        env: nil,
        timeoutSec: 5
    )

    guard let completion = await manager.waitForCompletion(commandId: started.commandId) else {
        Issue.record("Expected completion")
        return
    }

    #expect(completion.exitCode == 0)
    #expect(completion.stdoutTail.contains("truncated"))
}

@Test("Claude JSON parser handles successful output")
func parseClaudeJSONSuccess() {
    let parsed = parseClaudeCLIResult(
        from: "{\"type\":\"result\",\"result\":\"Applied fix\",\"session_id\":\"abc-123\",\"is_error\":false}"
    )

    #expect(parsed?.result == "Applied fix")
    #expect(parsed?.sessionId == "abc-123")
    #expect(parsed?.isError == false)
}

@Test("Claude JSON parser returns the last result event from stream-json output")
func parseClaudeJSONLastResultWins() {
    let parsed = parseClaudeCLIResult(
        from: """
        {"type":"assistant","message":{"content":[{"type":"text","text":"thinking"}]}}
        {"type":"result","result":"first","session_id":"abc-123","is_error":false}
        {"type":"result","result":"final","session_id":"abc-123","is_error":false}
        """
    )

    #expect(parsed?.result == "final")
}

@Test("Claude JSON parser handles error output")
func parseClaudeJSONError() {
    let parsed = parseClaudeCLIResult(
        from: "{\"type\":\"result\",\"result\":\"Not logged in\",\"session_id\":\"abc-123\",\"is_error\":true}"
    )

    #expect(parsed?.result == "Not logged in")
    #expect(parsed?.isError == true)
}

@Test("Claude stream state parses a final line without trailing newline")
func claudeStreamStateFlushesFinalLine() {
    var state = ClaudeCLIStreamState()
    state.ingest(
        chunk: "{\"type\":\"result\",\"result\":\"Applied fix\",\"session_id\":\"abc-123\",\"is_error\":false}",
        isFinal: false
    )

    #expect(state.lastResult == nil)

    state.finalize()
    #expect(state.lastResult?.result == "Applied fix")
}

@Test("Claude tool list normalization trims whitespace")
func normalizedClaudeTools() {
    #expect(normalizedClaudeToolList(" Bash, Read ,Write  ") == "Bash,Read,Write")
    #expect(normalizedClaudeToolList("   ") == nil)
}
