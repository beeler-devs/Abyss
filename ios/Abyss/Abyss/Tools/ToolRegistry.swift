import Foundation

/// Maps tool names to their type-erased handlers.
/// Extensible: register new tools at startup or dynamically.
@MainActor
final class ToolRegistry {
    private var tools: [String: AnyTool] = [:]

    /// Register a tool. Overwrites any existing tool with the same name.
    func register<T: Tool>(_ tool: T) {
        tools[T.name] = AnyTool(tool)
    }

    /// Look up a tool by name.
    func tool(named name: String) -> AnyTool? {
        tools[name]
    }

    /// All registered tool names.
    var registeredNames: [String] {
        Array(tools.keys).sorted()
    }
}
