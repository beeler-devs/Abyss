import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ConversationViewModel()
    @State private var showSettings = false
    @State private var showEventTimeline = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // API key warning banner
                if !Config.isAPIKeyConfigured {
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
                HStack(alignment: .center, spacing: 20) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEventTimeline.toggle()
                        }
                    } label: {
                        Image(systemName: showEventTimeline ? "list.bullet.circle.fill" : "list.bullet.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    MicButton(
                        appState: viewModel.appState,
                        recordingMode: viewModel.recordingMode,
                        onTap: { viewModel.micTapped() },
                        onPressDown: { viewModel.micPressed() },
                        onPressUp: { viewModel.micReleased() }
                    )

                    Spacer()

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 30)
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
