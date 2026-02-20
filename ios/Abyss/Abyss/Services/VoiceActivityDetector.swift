import Foundation
import Combine

/// Lightweight VAD based on microphone level in decibels.
/// Detection-only service: caller owns audio capture and feeds levels.
final class VoiceActivityDetector: NSObject, ObservableObject {
    struct Config {
        var silenceThreshold: Float = -40.0
        var speechThreshold: Float = -35.0
        var silenceDuration: TimeInterval = 1.5
        var minSpeechDuration: TimeInterval = 0.3
    }

    @Published private(set) var isMonitoring = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var audioLevel: Float = -160.0
    @Published private(set) var speechLog: [String] = []

    var onSpeechStarted: (() -> Void)?
    var onSpeechEnded: ((TimeInterval) -> Void)?

    private let config: Config
    private var silenceTimer: Timer?
    private var speechStartTime: Date?

    init(config: Config = Config()) {
        self.config = config
        super.init()
    }

    func startMonitoring() {
        runOnMain {
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
            self.speechStartTime = nil
            self.isSpeaking = false
            self.isMonitoring = true
            self.log("VAD monitoring started")
        }
    }

    func stopMonitoring() {
        runOnMain {
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
            self.speechStartTime = nil
            self.isMonitoring = false
            self.isSpeaking = false
            self.log("Monitoring stopped")
        }
    }

    func processAudioLevel(_ level: Float) {
        runOnMain {
            guard self.isMonitoring else { return }

            self.audioLevel = level
            self.detectVoiceActivity(level: level)
        }
    }

    private func detectVoiceActivity(level: Float) {
        if level > config.speechThreshold {
            handleSpeechDetected()
        } else if level < config.silenceThreshold {
            handleSilenceDetected()
        }
    }

    private func handleSpeechDetected() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        guard !isSpeaking else { return }

        isSpeaking = true
        speechStartTime = Date()
        log("Speech detected")
        onSpeechStarted?()
    }

    private func handleSilenceDetected() {
        guard isSpeaking else { return }
        guard silenceTimer == nil else { return }

        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: config.silenceDuration,
            repeats: false
        ) { [weak self] _ in
            self?.handleSpeechEnded()
        }
    }

    private func handleSpeechEnded() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        guard isSpeaking, let startTime = speechStartTime else { return }

        let duration = Date().timeIntervalSince(startTime)
        isSpeaking = false
        speechStartTime = nil

        guard duration >= config.minSpeechDuration else {
            log("Ignored short speech burst (\(String(format: "%.1f", duration))s)")
            return
        }

        log("Speech ended (duration: \(String(format: "%.1f", duration))s)")
        onSpeechEnded?(duration)
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )

        speechLog.insert("[\(timestamp)] \(message)", at: 0)
        if speechLog.count > 20 {
            speechLog.removeLast()
        }
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
