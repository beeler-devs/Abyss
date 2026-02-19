import SwiftUI

@main
struct AbyssApp: App {
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @StateObject private var chatList = ChatListViewModel()
    @StateObject private var authManager = GitHubAuthManager()

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView(chatList: chatList)
                .environmentObject(authManager)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
