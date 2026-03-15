# iOS Markdown Rendering & Code Block Display

## Overview

The iOS client now includes full markdown rendering and code block display capabilities through the `MarkdownTextView` component. This enables rich, formatted responses from the LLM that include inline formatting, fenced code blocks with syntax highlighting, and copy-to-clipboard functionality.

## Features

### Inline Markdown Formatting

The iOS app supports standard markdown inline formatting in assistant responses:

- **Bold text** (`**text**`)
- *Italic text* (`*text*`)
- `Inline code` (`` `code` ``)
- Links (`[text](url)`)
- Other inline markdown elements

Inline formatting is rendered using SwiftUI's native `AttributedString` with markdown support, ensuring proper rendering across light and dark modes.

### Fenced Code Blocks

Code blocks are fully supported with the following features:

#### Syntax Support

```swift
// Code blocks are declared with triple backticks
```python
def example():
    return "This will be rendered as a code block"
```
```

#### Visual Features

- **Language Labels**: Code blocks display the language identifier (e.g., "python", "swift", "javascript") in a small label at the top-left
- **Syntax Highlighting Colors**: Theme-aware background and text colors optimized for readability
- **Copy Button**: Each code block includes a copy button (top-right) that:
  - Copies the code content to clipboard
  - Shows a checkmark animation on successful copy
  - Automatically resets after 1.5 seconds
- **Horizontal Scrolling**: Long lines of code can be scrolled horizontally without wrapping
- **Text Selection**: All code content is selectable for manual copying

#### Styling

Code blocks use a distinct visual style:
- Rounded corners (8pt radius)
- Monospaced font (system `.footnote` size)
- Theme-aware colors via `AppTheme`:
  - `codeBlockBackground`: Subtle background color (light/dark mode aware)
  - `codeBlockText`: High-contrast text color for code content
  - `codeBlockLabelText`: Muted color for language label and copy icon

### Text Selection

All rendered content (both inline markdown and code blocks) supports text selection, allowing users to copy any part of the assistant's response.

## Architecture Integration

### Component Structure

```
TranscriptView (Conversation display)
  └─ MessageBubble (Individual message wrapper)
      └─ MarkdownTextView (Markdown parser & renderer)
          ├─ Text (Inline formatted content)
          └─ CodeBlockView (Fenced code blocks)
```

### Usage in TranscriptView

Assistant messages automatically use `MarkdownTextView` for rendering:

```swift
if isUser {
    Text(message.text)  // Plain text for user messages
} else {
    MarkdownTextView(text: message.text, foregroundColor: textColor)  // Markdown for assistant
}
```

User messages continue to render as plain text, while all assistant responses are parsed and rendered with markdown support.

### Parsing Logic

The `MarkdownTextView.parse(_:)` method splits message text into blocks:

1. Detects fenced code blocks (lines starting with `` ``` ``)
2. Extracts language identifier from opening fence
3. Accumulates non-code content as text blocks
4. Returns array of `.text(String)` and `.codeBlock(language: String?, code: String)` blocks

Each block is rendered independently:
- Text blocks → SwiftUI `AttributedString` with inline markdown
- Code blocks → `CodeBlockView` with syntax highlighting UI

## Implications for Backend & LLM Responses

### Server-Side Considerations

The server **does not need to change** to support markdown rendering. The iOS client automatically parses and renders markdown from any assistant response text.

### LLM Response Formatting

When configuring LLM providers (Anthropic Claude, Amazon Nova, etc.), responses can now include:

1. **Inline Markdown**: The LLM can use markdown formatting in natural responses
2. **Code Blocks**: Multi-line code examples should use triple-backtick fenced blocks with language identifiers

Example LLM response:

```
Here's a Python function to calculate factorial:

```python
def factorial(n):
    if n <= 1:
        return 1
    return n * factorial(n - 1)
```

This uses **recursion** to compute the result.
```

The iOS client will automatically:
- Parse the code block
- Display "python" as the language label
- Render the code in a styled, copyable block
- Format "recursion" as bold text

### Streaming Considerations

Partial responses (`assistant.speech.partial` events) are rendered progressively:

- Incomplete code blocks are handled gracefully
- Text accumulates as the LLM streams tokens
- Code blocks become interactive once fully received (closing `` ``` `` detected)

### Tool Call Results

Code blocks are particularly useful for displaying:

- `bridge.exec.run` results (terminal output)
- `bridge.fs.read` file contents
- `agent.*` Cursor Cloud Agent logs or output
- Error messages with stack traces

The LLM can format these results with appropriate language identifiers (e.g., `bash`, `json`, `typescript`, `log`).

## Future Enhancements

Potential improvements to markdown rendering:

- [ ] Syntax-aware color highlighting (not just monochrome)
- [ ] Block-level markdown (headings, lists, quotes)
- [ ] Tables
- [ ] Images (inline or referenced)
- [ ] LaTeX/math rendering for technical responses
- [ ] Collapsible code blocks for very long snippets
- [ ] Line numbers for code blocks

## Testing Recommendations

To verify markdown rendering:

1. **Inline Formatting**: Ask the LLM to respond with bold, italic, and inline code
2. **Code Blocks**: Request code examples in various languages (Python, Swift, JavaScript, etc.)
3. **Mixed Content**: Get responses combining prose, inline code, and code blocks
4. **Edge Cases**:
   - Code blocks without language identifiers
   - Multiple consecutive code blocks
   - Code blocks with very long lines
   - Markdown special characters in code blocks (backticks, asterisks)
5. **Theme Switching**: Toggle between light and dark mode to verify color contrast

## Related Files

- `ios/Abyss/Abyss/Views/MarkdownTextView.swift` — Markdown parser and renderer
- `ios/Abyss/Abyss/Views/TranscriptView.swift` — Integration into conversation UI
- `server/src/core/conductorService.ts` — LLM response handling
- `server/src/providers/` — LLM provider implementations
