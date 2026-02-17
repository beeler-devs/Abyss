import Foundation

/// Every tool must conform to this protocol.
/// Tools are the ONLY way the conductor interacts with the system.
protocol Tool: Sendable {
    /// Unique dot-separated name, e.g. "stt.start", "convo.setState"
    static var name: String { get }

    /// The Codable type for the tool's arguments.
    associatedtype Arguments: Codable & Sendable
    /// The Codable type for the tool's result.
    associatedtype Result: Codable & Sendable

    /// Execute the tool with the given arguments.
    /// Runs on MainActor since tools may mutate observable state.
    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result
}

/// Type-erased wrapper so we can store heterogeneous tools in the registry.
struct AnyTool: Sendable {
    let name: String
    /// Takes JSON-encoded arguments, returns JSON-encoded result.
    let execute: @MainActor @Sendable (String) async throws -> String

    init<T: Tool>(_ tool: T) {
        self.name = T.name
        self.execute = { jsonArgs in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let arguments = try decoder.decode(T.Arguments.self, from: Data(jsonArgs.utf8))
            let result = try await tool.execute(arguments)
            let data = try encoder.encode(result)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }
}

/// Errors specific to the tool system.
enum ToolError: LocalizedError {
    case unknownTool(String)
    case argumentDecodingFailed(String, Error)
    case executionFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .argumentDecodingFailed(let name, let err):
            return "Failed to decode arguments for \(name): \(err.localizedDescription)"
        case .executionFailed(let name, let err):
            return "Tool \(name) failed: \(err.localizedDescription)"
        }
    }
}
