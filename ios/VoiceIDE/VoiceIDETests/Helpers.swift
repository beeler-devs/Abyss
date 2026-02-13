import Foundation
@testable import VoiceIDE

// MARK: - Mock SpeechTranscriber

final class MockSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _isListening = false
    var isListening: Bool {
        lock.withLock { _isListening }
    }

    var startCallCount = 0
    var stopCallCount = 0
    var mockFinalTranscript = "Hello test"
    private var continuation: AsyncStream<String>.Continuation?
    private var _partials: AsyncStream<String>?

    var partials: AsyncStream<String> {
        lock.withLock {
            if let existing = _partials { return existing }
            let (stream, cont) = AsyncStream<String>.makeStream()
            self._partials = stream
            self.continuation = cont
            return stream
        }
    }

    func start() async throws {
        lock.withLock {
            _isListening = true
            startCallCount += 1
        }
        // Recreate partials stream
        let (stream, cont) = AsyncStream<String>.makeStream()
        lock.withLock {
            self._partials = stream
            self.continuation = cont
        }
    }

    func stop() async throws -> String {
        lock.withLock {
            _isListening = false
            stopCallCount += 1
        }
        continuation?.finish()
        return mockFinalTranscript
    }

    func emitPartial(_ text: String) {
        continuation?.yield(text)
    }
}

// MARK: - Mock TextToSpeech

final class MockTextToSpeech: TextToSpeech, @unchecked Sendable {
    private let lock = NSLock()
    private var _isSpeaking = false
    var isSpeaking: Bool {
        lock.withLock { _isSpeaking }
    }

    var speakCallCount = 0
    var stopCallCount = 0
    var lastSpokenText: String?

    func speak(_ text: String) async throws {
        lock.withLock {
            _isSpeaking = true
            speakCallCount += 1
            lastSpokenText = text
        }
        // Simulate short speaking duration
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        lock.withLock { _isSpeaking = false }
    }

    func stop() async {
        lock.withLock {
            _isSpeaking = false
            stopCallCount += 1
        }
    }
}
