#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path

from hook_utils import cwd_from, emit_pretool, is_cs_path, read_payload, tool_input


def main() -> int:
    try:
        max_lines = int(os.environ.get("SERENA_FORGE_READ_MAXLINES", "100"))
    except ValueError:
        max_lines = 100
    if max_lines <= 0:
        return 0

    payload = read_payload()
    ti = tool_input(payload)
    file_path = ti.get("file_path")
    if not isinstance(file_path, str) or not is_cs_path(file_path):
        return 0

    cwd = cwd_from(payload)
    if not (cwd / ".serena").is_dir():
        return 0

    if ti.get("limit") not in (None, "") or ti.get("offset") not in (None, ""):
        return 0

    path = Path(file_path)
    if not path.is_file():
        return 0
    try:
        with path.open("rb") as fh:
            lines = sum(1 for _ in fh)
    except OSError:
        return 0
    if lines <= max_lines:
        return 0

    emit_pretool(
        "ask",
        f"This is a whole-file Read of a {lines}-line C# file. Prefer Serena: "
        "get_symbols_overview, then find_symbol with include_body only on the target symbol, "
        "and find_referencing_symbols for impact. Confirm only if you genuinely need the full file.",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(0)
