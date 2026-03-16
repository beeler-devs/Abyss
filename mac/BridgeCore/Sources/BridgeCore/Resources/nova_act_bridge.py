#!/usr/bin/env python3
"""
Long-lived Python process that wraps Amazon Nova Act for stdin/stdout JSON-RPC.

Protocol (one JSON object per line on stdin, one per line on stdout):

  → {"cmd":"start", "url":"...", "headless":true, "user_data_dir":"..."}
  ← {"ok":true}

  → {"cmd":"act", "instruction":"...", "schema":{...}}
  ← {"ok":true, "result":"...", "success":true}

  → {"cmd":"stop"}
  ← {"ok":true}

Errors: {"ok":false, "error":"..."}
Debug logging goes to stderr.
"""

import json
import sys
import traceback


def log(msg: str) -> None:
    print(f"[nova_act_bridge] {msg}", file=sys.stderr, flush=True)


def respond(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main() -> None:
    session = None

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            respond({"ok": False, "error": f"invalid JSON: {e}"})
            continue

        command = cmd.get("cmd")

        try:
            if command == "start":
                if session is not None:
                    respond({"ok": False, "error": "session already active"})
                    continue

                from nova_act import NovaAct  # noqa: late import

                url = cmd.get("url", "about:blank")
                headless = cmd.get("headless", True)
                user_data_dir = cmd.get("user_data_dir")

                kwargs = {
                    "starting_page": url,
                    "headless": headless,
                }
                if user_data_dir:
                    kwargs["user_data_dir"] = user_data_dir

                log(f"starting NovaAct session: url={url} headless={headless}")
                session = NovaAct(**kwargs)
                session.__enter__()
                log("NovaAct session started")
                respond({"ok": True})

            elif command == "act":
                if session is None:
                    respond({"ok": False, "error": "no active session"})
                    continue

                instruction = cmd.get("instruction", "")
                schema_raw = cmd.get("schema")

                kwargs = {}
                if schema_raw is not None:
                    if isinstance(schema_raw, str):
                        kwargs["schema"] = json.loads(schema_raw)
                    elif isinstance(schema_raw, dict):
                        kwargs["schema"] = schema_raw

                log(f"executing act: {instruction[:120]}")
                result = session.act(instruction, **kwargs)
                log(f"act complete: success={result.matches_schema}")

                response = {
                    "ok": True,
                    "result": json.dumps(result.parsed_response) if result.parsed_response is not None else str(result.response),
                    "success": bool(result.matches_schema),
                }
                respond(response)

            elif command == "stop":
                if session is not None:
                    log("stopping NovaAct session")
                    try:
                        session.__exit__(None, None, None)
                    except Exception:
                        log(f"error during session exit: {traceback.format_exc()}")
                    session = None
                respond({"ok": True})
                break  # exit process

            else:
                respond({"ok": False, "error": f"unknown command: {command}"})

        except Exception as e:
            log(f"error: {traceback.format_exc()}")
            respond({"ok": False, "error": str(e)})

    # Cleanup on stdin EOF
    if session is not None:
        log("stdin closed, cleaning up session")
        try:
            session.__exit__(None, None, None)
        except Exception:
            pass


if __name__ == "__main__":
    main()
