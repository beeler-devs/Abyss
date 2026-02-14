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

                Section("Cloud Conductor (Phase 2)") {
                    HStack {
                        Text("Backend")
                        Spacer()
                        if Config.useCloudConductor {
                            if Config.isBackendConfigured {
                                Label("Connected", systemImage: "cloud.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Label("URL Not Set", systemImage: "cloud.slash")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Label("Local Stub", systemImage: "desktopcomputer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if Config.useCloudConductor && Config.isBackendConfigured {
                        LabeledContent("WS URL") {
                            Text(Config.backendWebSocketURL)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "Phase 2")
                    LabeledContent("Architecture", value: "Tool-Calling")
                    LabeledContent("Conductor", value: Config.useCloudConductor ? "Cloud (Bedrock)" : "Local Stub")
                    LabeledContent("STT Engine", value: "WhisperKit")
                    LabeledContent("TTS Engine", value: "ElevenLabs")
                }

                if !Config.isAPIKeyConfigured || (Config.useCloudConductor && !Config.isBackendConfigured) {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Setup Required", systemImage: "info.circle")
                                .font(.subheadline.bold())

                            if !Config.isAPIKeyConfigured {
                                Text("Add ELEVENLABS_API_KEY to Secrets.plist for TTS.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if Config.useCloudConductor && !Config.isBackendConfigured {
                                Text("Add BACKEND_WS_URL to Secrets.plist for the cloud conductor.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text("See README for details.")
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
