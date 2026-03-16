import Foundation

/// Model representing a bridge command execution card in the transcript.
struct BridgeExecCard: Identifiable {
    let id: UUID
    var commandId: String?
    let callId: String
    var anchorMessageID: UUID?
    let command: String
    var deviceName: String?
    var status: Status
    var outputLines: String
    var exitCode: Int?
    var isExpanded: Bool
    let startedAt: Date
    var finishedAt: Date?

    enum Status {
        case running
        case finished
        case failed
    }

    /// Cap output at ~100KB, trimming from front when exceeded.
    private static let maxOutputBytes = 100_000

    init(
        id: UUID = UUID(),
        commandId: String? = nil,
        callId: String,
        anchorMessageID: UUID? = nil,
        command: String,
        deviceName: String? = nil,
        status: Status = .running,
        outputLines: String = "",
        exitCode: Int? = nil,
        isExpanded: Bool = false,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.commandId = commandId
        self.callId = callId
        self.anchorMessageID = anchorMessageID
        self.command = command
        self.deviceName = deviceName
        self.status = status
        self.outputLines = outputLines
        self.exitCode = exitCode
        self.isExpanded = isExpanded
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    mutating func appendOutput(_ chunk: String) {
        outputLines.append(chunk)
        if outputLines.utf8.count > Self.maxOutputBytes {
            let excess = outputLines.utf8.count - Self.maxOutputBytes
            let trimIndex = outputLines.utf8.index(outputLines.utf8.startIndex, offsetBy: excess)
            outputLines = String(outputLines[trimIndex...])
        }
    }
}
