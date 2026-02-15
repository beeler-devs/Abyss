import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ConversationViewModel()
    @State private var showSettings = false
    @State private var showEventTimeline = false
    @State private var isTypingMode = false
    @State private var typedMessage = ""

    private let controlHeight: CGFloat = 56
    private let iconColor = Color(red: 156 / 255, green: 156 / 255, blue: 156 / 255)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // API key warning banner
                if !Config.isElevenLabsAPIKeyConfigured {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("ElevenLabs API key not configured. TTS will fail.")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.15))
                }

                // State indicator
                StateIndicator(state: viewModel.appState)
                    .padding(.top, 8)

                // Conversation transcript
                TranscriptView(
                    messages: viewModel.messages,
                    partialTranscript: viewModel.partialTranscript,
                    appState: viewModel.appState
                )

                // Placeholder for future artifact cards
                if false { // Phase 2+
                    Text("Artifact cards will appear here")
                        .foregroundStyle(.secondary)
                }

                // Event timeline (collapsible)
                if showEventTimeline {
                    EventTimelineView(events: viewModel.eventBus.events)
                        .frame(maxHeight: 200)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Divider()

                // Bottom controls
                HStack(alignment: .center, spacing: 12) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(iconColor)
                            .frame(width: controlHeight, height: controlHeight)
                            .background(
                                RoundedRectangle(cornerRadius: controlHeight / 2)
                                    .fill(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
                            )
                    }
                    .buttonStyle(.plain)

                    MicButton(
                        appState: viewModel.appState,
                        recordingMode: viewModel.recordingMode,
                        isTypingMode: $isTypingMode,
                        typedText: $typedMessage,
                        onTap: { viewModel.micTapped() },
                        onPressDown: { viewModel.micPressed() },
                        onPressUp: { viewModel.micReleased() },
                        onSendTyped: { text in
                            viewModel.sendTypedMessage(text)
                        }
                    )

                    if !isTypingMode {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showEventTimeline.toggle()
                            }
                        } label: {
                            Image(systemName: showEventTimeline ? "list.bullet.circle.fill" : "list.bullet.circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(iconColor)
                                .frame(width: controlHeight, height: controlHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: controlHeight / 2)
                                        .fill(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(width: controlHeight, height: controlHeight)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle("VoiceIDE")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                SettingsView(recordingMode: $viewModel.recordingMode)
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred.")
            }
        }
    }
}

#Preview {
    ContentView()
}
