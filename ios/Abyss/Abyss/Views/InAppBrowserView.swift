import SwiftUI
import WebKit

// MARK: - URL + Identifiable (for .sheet(item:))

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Observable coordinator that any child view can use to open a URL in the in-app browser.
final class InAppBrowserCoordinator: ObservableObject {
    @Published var urlToOpen: URL?
}

/// SwiftUI wrapper around WKWebView for an in-app browser experience.
struct InAppBrowserView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var webState = WebViewState()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebView(url: url, state: webState)
                    .ignoresSafeArea(edges: .bottom)

                if webState.isLoading {
                    ProgressView(value: webState.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .navigationTitle(webState.pageTitle ?? url.host ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { webState.goBack?() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!webState.canGoBack)

                    Button { webState.goForward?() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!webState.canGoForward)

                    Spacer()

                    Button { webState.reload?() } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        UIApplication.shared.open(webState.currentURL ?? url)
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
    }
}

// MARK: - WebView State

private final class WebViewState: ObservableObject {
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageTitle: String?
    @Published var currentURL: URL?

    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    var reload: (() -> Void)?
}

// MARK: - WKWebView Wrapper

private struct WebView: UIViewRepresentable {
    let url: URL
    let state: WebViewState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.observe(webView)

        state.goBack = { [weak webView] in webView?.goBack() }
        state.goForward = { [weak webView] in webView?.goForward() }
        state.reload = { [weak webView] in webView?.reload() }

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: WebViewState
        private var observations: [NSKeyValueObservation] = []

        init(state: WebViewState) {
            self.state = state
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.isLoading) { [weak self] wv, _ in
                    Task { @MainActor in self?.state.isLoading = wv.isLoading }
                },
                webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                    Task { @MainActor in self?.state.estimatedProgress = wv.estimatedProgress }
                },
                webView.observe(\.canGoBack) { [weak self] wv, _ in
                    Task { @MainActor in self?.state.canGoBack = wv.canGoBack }
                },
                webView.observe(\.canGoForward) { [weak self] wv, _ in
                    Task { @MainActor in self?.state.canGoForward = wv.canGoForward }
                },
                webView.observe(\.title) { [weak self] wv, _ in
                    Task { @MainActor in self?.state.pageTitle = wv.title }
                },
                webView.observe(\.url) { [weak self] wv, _ in
                    Task { @MainActor in self?.state.currentURL = wv.url }
                },
            ]
        }
    }
}
