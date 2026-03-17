# README Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the top-level `README.md` into a polished, hackathon-judge-friendly overview that leads with product positioning, clearly explains the architecture and security model, and includes repository layout, quick start, and tech stack coverage including optional advanced AWS context infrastructure.

**Architecture:** This is a documentation-only change centered on `README.md`, grounded in the approved design spec. The new README should move from product story to proof points to system architecture, then into security, repository layout, tech stack, and concise setup guidance, while staying accurate to the current codebase.

**Tech Stack:** Markdown, GitHub README conventions, SwiftUI/iOS app architecture, Node.js/TypeScript WebSocket server, macOS Swift bridge, AWS Bedrock/Nova, optional Neptune/Titan context graph infrastructure.

---

## File Structure

- Modify: `README.md` — replace the current minimal overview with the full judge-oriented README.
- Reference: `docs/superpowers/specs/2026-03-16-readme-redesign-design.md` — approved design/specification for the rewrite.
- Reference: `CLAUDE.md` — source of repo-wide architecture, feature, and operational details that the README must reflect accurately.

## Chunk 1: Rewrite Top-Level README

### Task 1: Replace README with approved structure and accurate content

**Files:**
- Modify: `README.md`
- Reference: `docs/superpowers/specs/2026-03-16-readme-redesign-design.md`
- Reference: `server/package.json`
- Reference: `server/.env.example`
- Reference: `scripts/dev/start-local.sh`

- [ ] **Step 1: Re-read the current README and approved spec**

Read:
- `README.md`
- `docs/superpowers/specs/2026-03-16-readme-redesign-design.md`

Expected:
- clear understanding of the new section order
- compact diagram placeholder near the top
- explicit judge-facing product framing

- [ ] **Step 2: Draft the new README content**

Write a replacement README with these sections in order:
- title + tagline + short overview
- `Tech Stack / Architecture Diagram` placeholder near the top
- above-the-fold proof / built-today section
- feature list near the top
- why Abyss
- how it works
- security and permissioning
- repository layout
- tech stack
- quick start
- current state

Constraints:
- position Abyss as voice-first, iPhone-native, secure, with coding as a flagship workflow
- keep advanced AWS memory/context infrastructure explicitly labeled optional
- avoid stale paths and old project names
- keep quick start practical and concise

- [ ] **Step 3: Verify technical claims against the repo**

Check the rewritten README against:
- `CLAUDE.md`
- `server/package.json`
- `server/.env.example`
- `scripts/dev/start-local.sh`

Expected:
- no overclaiming optional infrastructure as always-on
- no inaccurate auth/security statements
- quick start commands and paths match the current repository

- [ ] **Step 4: Review Markdown readability**

Verify:
- headings are easy to scan
- repository tree is readable
- bullets are concise
- the top of the README reads well for hackathon judges on GitHub

Expected:
- product pitch and proof remain visible in the first screenful
- diagram placeholder stays compact

- [ ] **Step 5: Run documentation sanity checks**

Run:
- read the final `README.md`
- check lints/diagnostics for changed docs if available

Expected:
- no malformed Markdown
- no obvious doc diagnostics introduced
