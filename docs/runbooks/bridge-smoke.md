# Bridge v0 Smoke Test

1. Start server:
   - `./scripts/dev/start-local.sh`
2. Launch bridge:
   - GUI: `cd mac/AbyssBridge && swift run`
   - CLI: `cd mac/BridgeCLI && swift run abyss-bridge --server ws://localhost:8080/ws --workspace /absolute/workspace --name "Dev Mac"`
3. In iOS app, pair using generated code.
4. Speak: `run echo hello`.
5. Confirm timeline contains:
   - `tool.call: bridge.exec.run`
   - `tool.result` with stdout including `hello`
6. Speak: `read file README.md`.
7. Confirm timeline contains `tool.call: bridge.fs.readFile` and content result.
