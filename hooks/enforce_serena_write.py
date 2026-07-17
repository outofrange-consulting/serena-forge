#!/usr/bin/env python3
"""PreToolUse guard for native C# writes.

Parses both Claude Code file-path payloads and Codex apply_patch payloads
without relying on platform-specific shell utilities.
It denies native .cs writes as a safety backstop; the session prompt provides
the non-blocking Serena-first guidance before the hook is needed.
"""
from __future__ import annotations

import re

from hook_utils import cwd_from, emit_pretool, is_cs_path, read_payload, tool_input

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
    onboarded = (cwd / ".serena").is_dir()
    if onboarded:
        reason = (
            f"serena-forge: native edit/patch of C# file '{target}' should go through Serena. "
            "Prefer get_symbols_overview/find_symbol, then replace_symbol_body, insert_after_symbol, "
            "insert_before_symbol, rename_symbol, safe_delete_symbol, or create_text_file. "
            "Native .cs edits remain denied; ask the user to fix Serena or disable the hook if Serena cannot perform the change."
        )
    else:
        reason = (
            f"serena-forge: native edit/patch of C# file '{target}' is protected and this repo is not "
            "Serena-onboarded yet (no .serena/ folder). Propose running the serena-forge-setup skill; "
            "native .cs edits remain denied until a human disables the hook or Serena is onboarded."
        )

    emit_pretool("deny", reason)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
