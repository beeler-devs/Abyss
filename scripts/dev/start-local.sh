#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required"
  exit 1
fi

echo "[abyss] starting local server..."
(
  cd "$SERVER_DIR"
  npm run dev
) &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

sleep 1

echo
echo "Abyss Bridge v0 local dev"
echo "========================="
echo "Server websocket: ws://localhost:8080/ws"
echo
echo "Launch Mac bridge (GUI):"
echo "  cd $ROOT_DIR/mac/AbyssBridge && swift run"
echo
echo "Launch Mac bridge (CLI):"
echo "  cd $ROOT_DIR/mac/BridgeCLI && swift run abyss-bridge --server ws://localhost:8080/ws --workspace $ROOT_DIR --name \"My Mac\""
echo
echo "Pairing steps:"
echo "  1) Generate/copy pairing code in AbyssBridge (or note CLI code)."
echo "  2) iOS app -> Settings -> Pair Computer -> enter code."
echo "  3) Say: run npm test (or run echo hello)."
echo "  4) Say: read file README.md"
echo
echo "Press Ctrl+C to stop."

wait "$SERVER_PID"
