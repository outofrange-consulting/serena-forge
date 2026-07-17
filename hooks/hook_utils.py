#!/usr/bin/env python3
"""Shared helpers for serena-forge hooks.

The hooks are intentionally fail-open on internal errors: helper functions avoid
raising for malformed payloads and emit only the JSON decisions requested by the
caller.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def read_payload() -> dict[str, Any]:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return {}
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def emit_pretool(decision: str, reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))


def emit_stop_block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))


def emit_session_context(context: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }, ensure_ascii=False))


def cwd_from(payload: dict[str, Any]) -> Path:
    cwd = payload.get("cwd")
    if isinstance(cwd, str) and cwd:
        return Path(cwd)
    return Path.cwd()


def tool_input(payload: dict[str, Any]) -> dict[str, Any]:
    value = payload.get("tool_input")
    return value if isinstance(value, dict) else {}


def is_cs_path(path: str | os.PathLike[str]) -> bool:
    return str(path).lower().endswith(".cs")


def is_generated_path(path: str | os.PathLike[str]) -> bool:
    s = str(path).replace("\\", "/").lower()
    name = s.rsplit("/", 1)[-1]
    return (
        name.endswith(".g.cs")
        or name.endswith(".generated.cs")
        or name.endswith(".designer.cs")
        or name.endswith(".assemblyinfo.cs")
        or "/generated/" in s
        or "/obj/" in s
        or "/bin/" in s
    )


def queue_path_for(cwd: Path) -> Path:
    # Stable enough for per-repo debounce and portable across Python platforms.
    import zlib

    key = zlib.crc32(str(cwd).encode("utf-8")) & 0xFFFFFFFF
    return Path(os.environ.get("TMPDIR") or os.environ.get("TEMP") or "/tmp") / f"serena-forge-build-queue-{key}"
