import SwiftUI

/// Settings sheet for configuring recording mode and API keys.
struct SettingsView: View {
    @Binding var recordingMode: RecordingMode
    @Environment(\.dismiss) private var dismiss

    @AppStorage("elevenLabsVoiceId") private var voiceId = "21m00Tcm4TlvDq8ikWAM"
    @AppStorage("elevenLabsModelId") private var modelId = "eleven_turbo_v2_5"

    var body: some View {
        NavigationStack {
            Form {
                Section("Recording Mode") {
                    Picker("Mode", selection: $recordingMode) {
                        Text("Tap to Toggle").tag(RecordingMode.tapToToggle)
                        Text("Press and Hold").tag(RecordingMode.pressAndHold)
                    }
                    .pickerStyle(.segmented)

                    switch recordingMode {
                    case .tapToToggle:
                        Label("Tap mic to start, tap again to stop", systemImage: "hand.tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .pressAndHold:
                        Label("Hold mic to record, release to stop", systemImage: "hand.tap.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("ElevenLabs TTS") {
                    HStack {
                        Text("API Key")
                        Spacer()
                        if Config.isAPIKeyConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Set", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    TextField("Voice ID", text: $voiceId)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Model ID", text: $modelId)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("About") {
                    LabeledContent("Version", value: "Phase 1")
                    LabeledContent("Architecture", value: "Tool-Calling")
                    LabeledContent("STT Engine", value: "WhisperKit")
                    LabeledContent("TTS Engine", value: "ElevenLabs")
                }

                if !Config.isAPIKeyConfigured {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Setup Required", systemImage: "info.circle")
                                .font(.subheadline.bold())

                            Text("Create a file at ios/VoiceIDE/VoiceIDE/App/Secrets.plist with your ELEVENLABS_API_KEY. See README for details.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
