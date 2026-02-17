import Foundation
import Combine

/// Append-only event stream that serves as the single source of truth.
/// Observable by the UI for timeline display, replayable for debugging.
@MainActor
final class EventBus: ObservableObject {
    @Published private(set) var events: [Event] = []

    private let subject = PassthroughSubject<Event, Never>()

    /// A publisher that emits each new event as it arrives.
    var stream: AnyPublisher<Event, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Append one event to the log and notify subscribers.
    func emit(_ event: Event) {
        events.append(event)
        subject.send(event)
    }

    /// Emit multiple events in order.
    func emit(_ batch: [Event]) {
        for event in batch {
            emit(event)
        }
    }

    /// Replay all events (useful for debugging / reconnect).
    func replay() -> [Event] {
        events
    }

    /// Clear all events (for session reset).
    func reset() {
        events.removeAll()
    }
}
