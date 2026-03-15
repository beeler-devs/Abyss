import SwiftUI

@main
struct AbyssApp: App {
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @StateObject private var chatList = ChatListViewModel()
    @StateObject private var authManager = GitHubAuthManager()
    @StateObject private var gmailAuthManager = GmailAuthManager()
    @StateObject private var browserCoordinator = InAppBrowserCoordinator()

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView(chatList: chatList)
                .environmentObject(authManager)
                .environmentObject(gmailAuthManager)
                .environmentObject(browserCoordinator)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
