import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders markdown text with inline formatting and styled fenced code blocks.
struct MarkdownTextView: View {
    let text: String
    var foregroundColor: Color = .primary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let content):
                    renderText(content)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    @ViewBuilder
    private func renderText(_ content: String) -> some View {
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.body)
                .foregroundStyle(foregroundColor)
                .textSelection(.enabled)
        } else {
            Text(content)
                .font(.body)
                .foregroundStyle(foregroundColor)
                .textSelection(.enabled)
        }
    }

    // MARK: - Parsing

    enum Block {
        case text(String)
        case codeBlock(language: String?, code: String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var currentText = ""
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                // Flush accumulated text
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingTrailingNewlines()))
                    currentText = ""
                }

                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language: String? = lang.isEmpty ? nil : lang
                var codeLines: [String] = []
                i += 1

                // Collect until closing ```
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                // Skip the closing ``` if found
                if i < lines.count { i += 1 }

                let code = codeLines.joined(separator: "\n")
                blocks.append(.codeBlock(language: language, code: code))
            } else {
                if !currentText.isEmpty { currentText += "\n" }
                currentText += line
                i += 1
            }
        }

        if !currentText.isEmpty {
            blocks.append(.text(currentText.trimmingTrailingNewlines()))
        }

        return blocks
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label and copy button
            HStack {
                if let language {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.codeBlockLabelText(for: colorScheme))
                }
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.codeBlockLabelText(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AppTheme.codeBlockText(for: colorScheme))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.codeBlockBackground(for: colorScheme))
        )
    }

    private func copyCode() {
#if canImport(UIKit)
        UIPasteboard.general.string = code
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
#endif
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
            }
        }
    }
}

// MARK: - String Extension

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}
