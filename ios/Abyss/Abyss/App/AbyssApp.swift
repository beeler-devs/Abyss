import SwiftUI

@main
struct AbyssApp: App {
    @StateObject private var chatList = ChatListViewModel()
    @StateObject private var authManager = GitHubAuthManager()

    var body: some Scene {
        WindowGroup {
            ContentView(chatList: chatList)
                .environmentObject(authManager)
        }
    }
}
