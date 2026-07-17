#!/usr/bin/env python3
"""PreToolUse guard for native C# writes.

Parses both Claude Code file-path payloads and Codex apply_patch payloads
without relying on platform-specific shell utilities.
It asks for user consent by default instead of hard-denying every .cs write, so
humans can intentionally override the guard while the agent is still steered to
Serena first.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from hook_utils import cwd_from, emit_pretool, is_cs_path, is_generated_path, read_payload, tool_input

PATCH_HEADER_RE = re.compile(r"^(?:\+\+\+|---|\*\*\* (?:Add|Update|Delete) File:)\s+(?P<path>\S+)", re.MULTILINE)


def extract_target(payload: dict) -> str:
    ti = tool_input(payload)
    file_path = ti.get("file_path")
    if isinstance(file_path, str) and file_path:
        return file_path

    command = ti.get("command")
    if not isinstance(command, str):
        return ""
    for match in PATCH_HEADER_RE.finditer(command):
        path = match.group("path")
        if path.startswith(("a/", "b/")):
            path = path[2:]
        if is_cs_path(path):
            return path
    return ""


def main() -> int:
    payload = read_payload()
    target = extract_target(payload)
    if not target or not is_cs_path(target):
        return 0

    cwd = cwd_from(payload)
    decision = os.environ.get("SERENA_FORGE_CS_WRITE_DECISION", "ask").lower()
    if decision not in {"ask", "deny"}:
        decision = "ask"

    # Generated C# artifacts are not valuable hand-authored source. Allowing the
    # native operation avoids friction for source-generator cleanup while the
    # normal permission flow and other guards still apply.
    if is_generated_path(target) and os.environ.get("SERENA_FORGE_GUARD_GENERATED", "0") != "1":
        return 0

    onboarded = (cwd / ".serena").is_dir()
    if onboarded:
        reason = (
            f"serena-forge: native edit/patch of C# file '{target}' should go through Serena. "
            "Prefer get_symbols_overview/find_symbol, then replace_symbol_body, insert_after_symbol, "
            "insert_before_symbol, rename_symbol, safe_delete_symbol, or create_text_file. "
            "Confirm only if this is a deliberate human-approved exception."
        )
    else:
        reason = (
            f"serena-forge: native edit/patch of C# file '{target}' is protected and this repo is not "
            "Serena-onboarded yet (no .serena/ folder). Propose running the serena-forge-setup skill; "
            "confirm only if the user explicitly wants to bypass Serena for this one operation."
        )

    emit_pretool(decision, reason)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
