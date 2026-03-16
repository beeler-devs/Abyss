import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders markdown text with inline formatting and styled fenced code blocks.
struct MarkdownTextView: View {
    let text: String
    var foregroundColor: Color = .primary
    var cardResolver: ((String, String) -> AnyView?)?

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
                case .list(let items, let ordered):
                    renderList(items, ordered: ordered)
                case .cardReference(let type, let id):
                    if let resolved = cardResolver?(type, id) {
                        resolved
                    } else {
                        CardPlaceholderView(state: .unresolved(type: type))
                    }
                case .cardPlaceholder(let partialInfo):
                    CardPlaceholderView(state: CardPlaceholderView.placeholderState(from: partialInfo))
                }
            }
        }
    }

    @ViewBuilder
    private func renderList(_ items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.body)
                        .foregroundStyle(foregroundColor)
                        .frame(minWidth: ordered ? 20 : 12, alignment: .leading)
                    renderInlineText(item)
                }
            }
        }
    }

    @ViewBuilder
    private func renderInlineText(_ content: String) -> some View {
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
        case list(items: [String], ordered: Bool)
        case cardReference(type: String, id: String)
        case cardPlaceholder(partialInfo: String)
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

                // Card reference: ```card:TYPE:CARD_ID
                if lang.hasPrefix("card:") {
                    let parts = lang.split(separator: ":", maxSplits: 2)
                    if parts.count == 3 {
                        blocks.append(.cardReference(type: String(parts[1]), id: String(parts[2])))
                    } else {
                        blocks.append(.cardPlaceholder(partialInfo: lang))
                    }
                    // Skip lines until closing ```
                    i += 1
                    while i < lines.count && !lines[i].hasPrefix("```") { i += 1 }
                    if i < lines.count { i += 1 }
                } else {
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
                }
            } else if let item = unorderedListItem(from: line) {
                // Flush accumulated text
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingTrailingNewlines()))
                    currentText = ""
                }
                var items = [item]
                i += 1
                while i < lines.count, let next = unorderedListItem(from: lines[i]) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(items: items, ordered: false))
            } else if let item = orderedListItem(from: line) {
                // Flush accumulated text
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingTrailingNewlines()))
                    currentText = ""
                }
                var items = [item]
                i += 1
                while i < lines.count, let next = orderedListItem(from: lines[i]) {
                    items.append(next)
                    i += 1
                }
                blocks.append(.list(items: items, ordered: true))
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

    private static func unorderedListItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func orderedListItem(from line: String) -> String? {
        // Matches "1. ", "2. ", etc.
        let parts = line.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let _ = Int(parts[0]),
              parts[1].hasPrefix(" ") else { return nil }
        return String(parts[1].dropFirst())
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
