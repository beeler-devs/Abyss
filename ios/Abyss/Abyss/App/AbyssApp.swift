import SwiftUI

@main
struct AbyssApp: App {
    @StateObject private var chatList = ChatListViewModel()
    @StateObject private var authManager = GitHubAuthManager()

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView(chatList: chatList)
                    .environmentObject(authManager)
            } else {
                GitHubLoginView(authManager: authManager)
            }
        }
    }
}
