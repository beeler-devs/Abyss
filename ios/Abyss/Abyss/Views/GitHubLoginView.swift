import SwiftUI

struct GitHubLoginView: View {
    @ObservedObject var authManager: GitHubAuthManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + wordmark
                VStack(spacing: 16) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.9))
                        .symbolRenderingMode(.hierarchical)

                    Text("Abyss")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Voice-first development assistant")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }

                Spacer()

                // Auth section
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("Connect your GitHub account")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("Abyss uses GitHub to list your repositories\nand organizations when you ask.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }

                    if let error = authManager.authError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        Task { await authManager.authenticate() }
                    } label: {
                        HStack(spacing: 10) {
                            if authManager.isAuthenticating {
                                ProgressView()
                                    .tint(.black)
                                    .scaleEffect(0.85)
                                Text("Connecting…")
                                    .fontWeight(.semibold)
                            } else {
                                Image(systemName: "link")
                                    .fontWeight(.semibold)
                                Text("Connect GitHub")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(authManager.isAuthenticating ? Color.white.opacity(0.7) : Color.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(authManager.isAuthenticating)
                    .animation(.easeInOut(duration: 0.2), value: authManager.isAuthenticating)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 56)
            }
        }
    }
}

#Preview {
    GitHubLoginView(authManager: GitHubAuthManager())
}
