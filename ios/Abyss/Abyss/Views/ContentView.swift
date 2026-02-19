import SwiftUI

struct ContentView: View {
    @ObservedObject var chatList: ChatListViewModel
    @State private var showSettings = false
    @State private var showEventTimeline = false
    @State private var isTypingMode = false
    @State private var typedMessage = ""

    private let iconColor = Color(red: 156 / 255, green: 156 / 255, blue: 156 / 255)

    private var viewModel: ConversationViewModel? {
        chatList.selectedChat?.viewModel
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar: chat list
            List(chatList.chats, selection: $chatList.selectedChatId) { chat in
                Button {
                    chatList.selectChat(id: chat.id)
                } label: {
                    Text(chat.title)
                        .lineLimit(1)
                }
                .tag(chat.id)
            }
            .navigationTitle("Chats")
        } detail: {
            NavigationStack {
                Group {
                    if let vm = viewModel {
                        ChatContentView(
                            viewModel: vm,
                            showEventTimeline: $showEventTimeline,
                            isTypingMode: $isTypingMode,
                            typedMessage: $typedMessage,
                            iconColor: iconColor
                        )
                    } else {
                        emptyState
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(iconColor)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        if let vm = viewModel {
                            StateIndicator(state: vm.appState)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            chatList.createChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(iconColor)
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    if let vm = viewModel {
                        SettingsView(
                            recordingMode: Binding(
                                get: { vm.recordingMode },
                                set: { vm.recordingMode = $0 }
                            ),
                            useServerConductor: Binding(
                                get: { vm.useServerConductor },
                                set: { vm.setUseServerConductor($0) }
                            )
                        )
                    } else {
                        SettingsView(
                            recordingMode: .constant(.tapToToggle),
                            useServerConductor: .constant(false)
                        )
                    }
                }
            }
        }
        .onAppear {
            if chatList.chats.isEmpty {
                chatList.createChat()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image("AbyssLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("No chat selected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button {
                chatList.createChat()
            } label: {
                Label("New Chat", systemImage: "plus.message")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// Chat content view that observes ConversationViewModel so UI updates propagate.
private struct ChatContentView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Binding var showEventTimeline: Bool
    @Binding var isTypingMode: Bool
    @Binding var typedMessage: String
    let iconColor: Color

    var body: some View {
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

            // Conversation transcript
            TranscriptView(messages: viewModel.messages)

            // Agent progress cards
            if !viewModel.agentProgressCards.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.agentProgressCards.prefix(2))) { card in
                        AgentProgressCardView(
                            card: card,
                            onRefresh: { viewModel.refreshAgentStatus(cardID: card.id) },
                            onCancel: { viewModel.cancelAgent(cardID: card.id) },
                            onDismiss: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.dismissAgentCard(cardID: card.id)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            // Event timeline (collapsible)
            if showEventTimeline {
                EventTimelineView(events: viewModel.eventBus.events)
                    .frame(maxHeight: 200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider()

            // Bottom controls
            HStack(alignment: .center, spacing: UIConstants.actionBarSpacing) {
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
                            .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                            .foregroundStyle(iconColor)
                            .frame(width: UIConstants.actionBarControlHeight, height: UIConstants.actionBarControlHeight)
                            .background(
                                RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
                                    .fill(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: UIConstants.actionBarControlHeight, height: UIConstants.actionBarControlHeight)
                }
            }
            .padding(.horizontal, UIConstants.actionBarHorizontalPadding)
            .padding(.top, UIConstants.actionBarTopPadding)
            .padding(.bottom, UIConstants.actionBarBottomPadding)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.showError },
            set: { viewModel.showError = $0 }
        )) {
            Button("OK") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred.")
        }
    }
}

#Preview {
    ContentView(chatList: ChatListViewModel())
}
