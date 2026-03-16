import SwiftUI

/// Animated thinking indicator with cycling words and a shimmer/sheen effect.
/// Shows "Thinking..." → "Pondering..." → "Processing..." etc., cycling every 4 seconds.
struct ThinkingIndicatorView: View {
    var font: Font = .body
    var baseColor: Color = .secondary

    private static let words = [
        "Thinking",
        "Pondering",
        "Processing",
        "Reasoning",
        "Analyzing",
        "Considering",
        "Working",
        "Reflecting",
        "Computing",
        "Mulling",
        "Formulating",
        "Crafting",
    ]

    @State private var wordIndex: Int = Int.random(in: 0..<words.count)
    @State private var shimmerPhase: CGFloat = -1.0

    private var currentWord: String {
        Self.words[wordIndex % Self.words.count] + "..."
    }

    var body: some View {
        Text(currentWord)
            .font(font)
            .foregroundStyle(.clear)
            .overlay {
                shimmerGradient
                    .mask {
                        Text(currentWord)
                            .font(font)
                    }
            }
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.4), value: wordIndex)
            .onAppear {
                startShimmer()
            }
            .onReceive(wordCycleTimer) { _ in
                wordIndex = (wordIndex + 1) % Self.words.count
            }
    }

    private var shimmerGradient: some View {
        GeometryReader { geo in
            let width = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: baseColor, location: 0),
                    .init(color: baseColor, location: max(0, shimmerPhase - 0.15)),
                    .init(color: sheenHighlight, location: shimmerPhase),
                    .init(color: baseColor, location: min(1, shimmerPhase + 0.15)),
                    .init(color: baseColor, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width)
        }
    }

    private var sheenHighlight: Color {
        .white
    }

    private func startShimmer() {
        shimmerPhase = -0.3
        withAnimation(
            .linear(duration: 2.0)
            .repeatForever(autoreverses: false)
        ) {
            shimmerPhase = 1.3
        }
    }

    private var wordCycleTimer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()
    }
}

import Combine
