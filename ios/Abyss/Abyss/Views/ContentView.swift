import SwiftUI

struct ContentView: View {
    @ObservedObject var chatList: ChatListViewModel
    @EnvironmentObject private var browserCoordinator: InAppBrowserCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSettings = false
    @State private var showEventTimeline = false
    @State private var isTypingMode = false
    @State private var typedMessage = ""
    @State private var showSidebar = false
    @State private var activeChatId: UUID?
    @AppStorage("recordingMode") private var recordingModeRaw: String = RecordingMode.vadAuto.rawValue

    private var recordingMode: RecordingMode {
        RecordingMode(rawValue: recordingModeRaw) ?? .vadAuto
    }

    private var viewModel: ConversationViewModel? {
        chatList.selectedChat?.viewModel
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content
            NavigationStack {
                Group {
                    if let vm = viewModel {
                        ChatContentView(
                            viewModel: vm,
                            showEventTimeline: $showEventTimeline,
                            isTypingMode: $isTypingMode,
                            typedMessage: $typedMessage
                        )
                    } else {
                        emptyState
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showSidebar = true
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        if let vm = viewModel, recordingMode != .pushToTalk {
                            StateIndicator(state: vm.appState, isMuted: vm.isMuted)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            chatList.createChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .offset(y: -2)
                                .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                if let vm = viewModel {
                    SettingsView(
                        pairedBridgeDevices: vm.pairedBridgeDevices,
                        bridgePairingMessage: vm.bridgePairingMessage,
                        onPairComputer: { code, deviceName in
                            vm.requestBridgePairing(pairingCode: code, deviceName: deviceName)
                        }
                    )
                } else {
                    SettingsView(
                        pairedBridgeDevices: [],
                        bridgePairingMessage: nil,
                        onPairComputer: nil
                    )
                }
            }

            // Dimming overlay when sidebar is open
            Color.black
                .opacity(showSidebar ? 0.35 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(showSidebar)
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showSidebar = false
                    }
                }

            // Left slide-in chat panel
            ChatSidebarPanel(
                chatList: chatList,
                showSidebar: $showSidebar,
                showSettings: $showSettings
            )
            .frame(width: 280)
            .offset(x: showSidebar ? 0 : -280)
        }
        .sheet(item: $browserCoordinator.urlToOpen) { url in
            InAppBrowserView(url: url)
        }
        .onAppear {
            if chatList.chats.isEmpty {
                chatList.createChat()
            }
            syncActiveChat(with: chatList.selectedChatId)
        }
        .onChange(of: chatList.selectedChatId) { _, newValue in
            syncActiveChat(with: newValue)
        }
        .onDisappear {
            if let activeChatId,
               let vm = chatList.chats.first(where: { $0.id == activeChatId })?.viewModel {
                vm.setChatActive(false)
            }
            self.activeChatId = nil
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .glassButtonBackground(cornerRadius: 20, colorScheme: colorScheme)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncActiveChat(with newSelectedId: UUID?) {
        if let currentActive = activeChatId,
           currentActive != newSelectedId,
           let vm = chatList.chats.first(where: { $0.id == currentActive })?.viewModel {
            vm.setChatActive(false)
        }

        guard let newSelectedId,
              let vm = chatList.chats.first(where: { $0.id == newSelectedId })?.viewModel else {
            activeChatId = nil
            return
        }

        activeChatId = newSelectedId
        vm.setChatActive(true)
    }

}

// MARK: - Chat Sidebar Panel

private struct ChatSidebarPanel: View {
    @ObservedObject var chatList: ChatListViewModel
    @Binding var showSidebar: Bool
    @Binding var showSettings: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chats")
                    .font(.title2.bold())
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showSidebar = false
                    }
                    chatList.createChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 16)

            Divider()

            // Chat list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(chatList.chats) { chat in
                        ChatRowButton(
                            chat: chat,
                            isSelected: chatList.selectedChatId == chat.id,
                            onSelect: {
                                chatList.selectChat(id: chat.id)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    showSidebar = false
                                }
                            },
                            onDelete: {
                                chatList.deleteChat(id: chat.id)
                            }
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Footer: Settings
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showSidebar = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showSettings = true
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .background(
            (colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.97))
                .ignoresSafeArea()
        )
        .ignoresSafeArea(edges: .vertical)
    }
}

// MARK: - Chat Row Button

private struct ChatRowButton: View {
    let chat: ChatSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 22)
                Text(chat.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.accentColor
                          : Color.clear)
            )
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Chat content view that observes ConversationViewModel so UI updates propagate.
private struct ChatContentView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Binding var showEventTimeline: Bool
    @Binding var isTypingMode: Bool
    @Binding var typedMessage: String
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("recordingMode") private var recordingModeRaw: String = RecordingMode.vadAuto.rawValue

    private var recordingMode: RecordingMode {
        RecordingMode(rawValue: recordingModeRaw) ?? .vadAuto
    }

    private func isPTTRecording(viewModel: ConversationViewModel, recordingMode: RecordingMode) -> Bool {
        if recordingMode == .pushToTalk {
            return viewModel.isPTTHeld
        }
        return viewModel.appState == .listening
    }

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
                .background(AppTheme.warningBannerBackground(for: colorScheme))
            }

            // Conversation transcript
            TranscriptView(
                messages: viewModel.messages,
                agentProgressCards: viewModel.agentProgressCards,
                partialTranscript: viewModel.partialTranscript,
                assistantPartialSpeech: viewModel.assistantPartialSpeech,
                appState: viewModel.appState,
                onRefreshAgent: { viewModel.refreshAgentStatus(cardID: $0) },
                onCancelAgent: { viewModel.cancelAgent(cardID: $0) },
                onDismissAgent: { cardID in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.dismissAgentCard(cardID: cardID)
                    }
                },
                onToggleAgentConversation: { viewModel.toggleConversationExpanded(cardID: $0) },
                onToggleAgentExpanded: { viewModel.toggleAgentCardExpanded(cardID: $0) }
            )

            // Repository selection card (takes priority)
            if let selectionCard = viewModel.repositorySelectionManager.activeCard {
                RepositorySelectionCardView(
                    card: selectionCard,
                    onSelect: { viewModel.selectRepository($0) },
                    onCancel: { viewModel.cancelRepositorySelection() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Event timeline (collapsible)
            if showEventTimeline {
                EventTimelineView(events: viewModel.eventBus.events)
                    .frame(maxHeight: 200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Bottom controls
            HStack(alignment: .center, spacing: UIConstants.actionBarSpacing) {
                MicButton(
                    isMuted: viewModel.isMuted,
                    isSpeaking: viewModel.appState == .speaking,
                    isTypingMode: $isTypingMode,
                    typedText: $typedMessage,
                    recordingMode: recordingMode,
                    isRecording: isPTTRecording(viewModel: viewModel, recordingMode: recordingMode),
                    showEventTimeline: showEventTimeline,
                    onToggleMute: { viewModel.toggleMute() },
                    onInterruptSpeaking: { viewModel.interruptAssistantSpeech() },
                    onMicPressed: { viewModel.micPressed() },
                    onMicReleased: { viewModel.micReleased() },
                    onSendTyped: { text in
                        viewModel.sendTypedMessage(text)
                    },
                    onToggleEventTimeline: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEventTimeline.toggle()
                        }
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
                            .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                            .frame(width: UIConstants.actionBarControlHeight, height: UIConstants.actionBarControlHeight)
                            .glassButtonBackground(cornerRadius: UIConstants.actionBarControlHeight / 2, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
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
        .environmentObject(InAppBrowserCoordinator())
}
