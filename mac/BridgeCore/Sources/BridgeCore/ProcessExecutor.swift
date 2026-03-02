import Foundation

public struct ProcessExecutor: Sendable {
    public init() {}

    public func run(
        command: String,
        cwd: URL,
        timeoutSec: Int,
        outputLimitBytes: Int
    ) throws -> CommandExecutionResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutTruncated = false
        var stderrTruncated = false
        let lock = NSLock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            if stdoutData.count < outputLimitBytes {
                let remaining = outputLimitBytes - stdoutData.count
                if data.count > remaining {
                    stdoutTruncated = true
                }
                stdoutData.append(data.prefix(remaining))
            } else {
                stdoutTruncated = true
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            if stderrData.count < outputLimitBytes {
                let remaining = outputLimitBytes - stderrData.count
                if data.count > remaining {
                    stderrTruncated = true
                }
                stderrData.append(data.prefix(remaining))
            } else {
                stderrTruncated = true
            }
        }

        try process.run()

        let timeoutResult = waitForExit(process: process, timeoutSec: timeoutSec)

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdout = appendTruncationMarkerIfNeeded(
            truncate(String(decoding: stdoutData, as: UTF8.self), maxBytes: outputLimitBytes),
            truncated: stdoutTruncated
        )
        var stderr = appendTruncationMarkerIfNeeded(
            truncate(String(decoding: stderrData, as: UTF8.self), maxBytes: outputLimitBytes),
            truncated: stderrTruncated
        )
        if timeoutResult.timedOut {
            if stderr.isEmpty {
                stderr = "Command timed out after \(timeoutSec)s"
            } else {
                stderr += "\nCommand timed out after \(timeoutSec)s"
            }
        }

        return CommandExecutionResult(
            exitCode: timeoutResult.exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: timeoutResult.timedOut
        )
    }

    private func waitForExit(process: Process, timeoutSec: Int) -> (exitCode: Int32, timedOut: Bool) {
        let timeout = max(1, timeoutSec)
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        let result = group.wait(timeout: .now() + .seconds(timeout))
        if result == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + .seconds(1))
            return (exitCode: -1, timedOut: true)
        }

        return (exitCode: process.terminationStatus, timedOut: false)
    }
}

private func appendTruncationMarkerIfNeeded(_ value: String, truncated: Bool) -> String {
    guard truncated, !value.contains("...[truncated]") else {
        return value
    }
    return value + "\n...[truncated]"
}
