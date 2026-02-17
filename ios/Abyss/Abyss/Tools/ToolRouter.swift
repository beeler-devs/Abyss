import Foundation

/// Receives tool.call events, dispatches to the registry, emits tool.result events.
/// This is the ONLY component that actually executes tools.
@MainActor
final class ToolRouter {
    private let registry: ToolRegistry
    private let eventBus: EventBus

    init(registry: ToolRegistry, eventBus: EventBus) {
        self.registry = registry
        self.eventBus = eventBus
    }

    /// Handle a single tool call event. Returns the result event.
    @discardableResult
    func dispatch(_ toolCall: Event.ToolCall) async -> Event {
        guard let tool = registry.tool(named: toolCall.name) else {
            let resultEvent = Event.toolError(
                callId: toolCall.callId,
                error: "Unknown tool: \(toolCall.name)"
            )
            eventBus.emit(resultEvent)
            return resultEvent
        }

        do {
            let resultJSON = try await tool.execute(toolCall.arguments)
            let resultEvent = Event.toolResult(callId: toolCall.callId, result: resultJSON)
            eventBus.emit(resultEvent)
            return resultEvent
        } catch {
            let resultEvent = Event.toolError(
                callId: toolCall.callId,
                error: error.localizedDescription
            )
            eventBus.emit(resultEvent)
            return resultEvent
        }
    }

    /// Process a batch of events, dispatching any tool.call events in order.
    func processEvents(_ events: [Event]) async {
        for event in events {
            // Emit non-tool-call events directly
            switch event.kind {
            case .toolCall(let tc):
                // Emit the tool.call event first, then dispatch it
                eventBus.emit(event)
                await dispatch(tc)
            default:
                eventBus.emit(event)
            }
        }
    }
}
