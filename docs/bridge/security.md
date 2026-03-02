# Bridge Security (v0)

Bridge v0 applies minimal but strict local execution controls.

## Workspace Allowlist

- A workspace root is selected explicitly by the user.
- All file access and working directories are resolved relative to that root.
- Absolute paths and path traversal (`..`) outside the root are rejected.

## macOS Workspace Persistence

- mac app stores workspace using security-scoped bookmarks.
- Bookmark is resolved at startup.

## Command Execution Guardrails

- `bridge.exec.run` enforces timeout (default `60s`, max `600s`).
- stdout/stderr are truncated to bounded size before returning.
- timeout surfaces as tool error payload with non-success exit code.

## Secrets

- No secrets committed in repo.
- Server/API credentials live in local env (`.env`, `Secrets.plist`).

## Future Hardening

- QR pairing
- signed short-lived bridge registration tokens
- command allow/deny policy lists
- per-session attestation
