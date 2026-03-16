#!/usr/bin/env python3
"""
Long-lived Python process that wraps Amazon Nova Act for stdin/stdout JSON-RPC.

Protocol (one JSON object per line on stdin, one per line on stdout):

  → {"cmd":"start", "url":"...", "headless":false, "user_data_dir":"..."}
  ← {"ok":true}

  → {"cmd":"act", "instruction":"...", "schema":{...}}
  ← {"ok":true, "result":"...", "success":true, "page_context":"..."}

  → {"cmd":"stop"}
  ← {"ok":true}

Errors: {"ok":false, "error":"..."}
Debug logging goes to stderr.
"""

import json
import os
import sys
import traceback


def log(msg: str) -> None:
    print(f"[nova_act_bridge] {msg}", file=sys.stderr, flush=True)


def respond(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


PAGE_SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "title": {"type": "string"},
    },
    "required": ["summary"],
}


def extract_page_context(session) -> str | None:
    """Best-effort extraction of current page content summary via act_get."""
    try:
        ctx = session.act_get(
            "Summarize the main content visible on this page in 2-3 sentences",
            schema=PAGE_SUMMARY_SCHEMA,
        )
        if ctx.parsed_response:
            return json.dumps(ctx.parsed_response)
        if ctx.response:
            return str(ctx.response)
    except Exception as e:
        log(f"page context extraction failed (non-fatal): {e}")
    return None


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
                headless = cmd.get("headless", False)
                user_data_dir = cmd.get("user_data_dir")

                kwargs = {
                    "starting_page": url,
                    "headless": headless,
                }
                api_key = os.environ.get("NOVA_ACT_API_KEY")
                if api_key:
                    kwargs["nova_act_api_key"] = api_key
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

                if schema_raw is not None:
                    # Schema provided — use act_get for structured extraction
                    if isinstance(schema_raw, str):
                        schema = json.loads(schema_raw)
                    elif isinstance(schema_raw, dict):
                        schema = schema_raw
                    else:
                        schema = schema_raw

                    log(f"executing act_get: {instruction[:120]}")
                    result = session.act_get(instruction, schema=schema)
                    log(f"act_get complete: matches_schema={result.matches_schema}")

                    response = {
                        "ok": True,
                        "result": json.dumps(result.parsed_response) if result.parsed_response is not None else str(result.response),
                        "success": bool(result.matches_schema) if result.matches_schema is not None else True,
                    }
                else:
                    # No schema — use act() which returns ActResult (no .response/.parsed_response)
                    log(f"executing act: {instruction[:120]}")
                    result = session.act(instruction)
                    log(f"act complete: steps={result.metadata.num_steps_executed} duration={result.metadata.time_worked_s}s")

                    response = {
                        "ok": True,
                        "result": json.dumps({
                            "steps": result.metadata.num_steps_executed,
                            "duration_s": result.metadata.time_worked_s,
                        }),
                        "success": True,
                    }

                    # Best-effort page context extraction after act()
                    page_context = extract_page_context(session)
                    if page_context:
                        response["page_context"] = page_context

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
